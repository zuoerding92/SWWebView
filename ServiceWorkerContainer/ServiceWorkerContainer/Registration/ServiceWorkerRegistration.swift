//
//  ServiceWorkerRegistration.swift
//  ServiceWorkerContainer
//
//  Created by alastair.coote on 13/06/2017.
//  Copyright © 2017 Guardian Mobile Innovation Lab. All rights reserved.
//

import Foundation
import PromiseKit
import ServiceWorker

@objc public class ServiceWorkerRegistration: NSObject, ServiceWorkerRegistrationProtocol {

    public func showNotification(title _: String) {
    }

    typealias RegisterCallback = (Error?) -> Void

    public let scope: URL
    public let id: String
    
//    fileprivate var _active: ServiceWorker?
//    public var active: ServiceWorker? {
//        get {
//            return _active;
//        }
//        set(value) {
//            self._active = value
//            if self.readyFulfill != nil {
//                self.readyFulfill!(self)
//                self.readyFulfill = nil
//            }
//        }
//    }
    
    public var active: ServiceWorker?
    public var waiting: ServiceWorker?
    public var installing: ServiceWorker?
    public var redundant: ServiceWorker?
    
//    fileprivate var readyPromise: Promise<ServiceWorkerRegistration>? = nil
//    fileprivate var readyFulfill: ((ServiceWorkerRegistration) -> Void)? = nil
//
//    public var ready:Promise<ServiceWorkerRegistration> {
//        get {
//            return self.readyPromise!
//        }
//    }

    fileprivate init(scope: URL, id: String) {
        self.scope = scope
        self.id = id
        super.init()
//        self.readyPromise = Promise { [unowned self] fulfill, reject in
//            self.readyFulfill = fulfill
//        }
    }

    func update() -> Promise<Void> {

        return firstly {

            var updateWorker: ServiceWorker?

            // Not sure of exactly how the logic should work here (do waiting workers count?) but we'll use both for now.
            // Ignoring installing workers because updating a worker that's currently installing makes no sense.

            if self.active != nil {
                updateWorker = self.active
            } else if self.waiting != nil {
                updateWorker = self.waiting
            }

            guard let worker = updateWorker else {
                throw ErrorMessage("No existing worker to update")
            }

            let request = try self.getUpdateRequest(forExistingWorker: worker)
            
            let newWorker = try self.createNewInstallingWorker(for: request.url)

            return FetchOperation.fetch(request)
                .then { res in

                    if res.status == 304 {
                        Log.info?("Ran update check for \(worker.url), received Not Modified response")
                        return Promise(value: ())
                    }

                    if res.ok != true {
                        throw ErrorMessage("Ran update check for \(worker.url), received unknown \(res.status) response")
                    }

                    return self.processHTTPResponse(res, newWorker: newWorker, byteCompareWorker: worker)
                }
        }
    }

    fileprivate func getUpdateRequest(forExistingWorker worker: ServiceWorker) throws -> FetchRequest {

        return try CoreDatabase.inConnection { db in

            let request = FetchRequest(url: worker.url)

            let existingHeaders = try db.select(sql: "SELECT headers FROM workers WHERE worker_id = ?", values: [worker.id]) { resultSet -> FetchHeaders? in

                if resultSet.next() == false {
                    return nil
                }

                let jsonString = try resultSet.string("headers")!
                return try FetchHeaders.fromJSON(jsonString)
            }

            // We attempt to use Last-Modified and ETag headers to minimise the amount of code we're downloading
            // as part of this update process. If we are updating an existing worker, we grab the headers seen at
            // the time.

            if let etag = existingHeaders?.get("ETag") {
                request.headers.append("If-None-Match", etag)
            }
            if let lastMod = existingHeaders?.get("Last-Modified") {
                request.headers.append("If-Modified-Since", lastMod)
            }

            return request
        }
    }
    
    fileprivate func createNewInstallingWorker(for url: URL) throws -> ServiceWorker {
        
        let newWorkerID = UUID().uuidString
        
        try CoreDatabase.inConnection { db in
            _ = try db.insert(sql: """
                INSERT INTO workers
                    (worker_id, url, install_state, scope)
                VALUES
                    (?,?,?,?)
            """, values: [
                newWorkerID,
                url,
                ServiceWorkerInstallState.installing.rawValue,
                self.scope,
                ])
        }
        
        let worker = try WorkerInstances.get(id: newWorkerID)
        self.installing = worker
        return worker
    }

    func register(_ workerURL: URL) -> Promise<Void> {
        
        // The install process is asynchronous and the register call doesn't wait for it.
        // So we create our stub in the database then return the promise immediately.
        
        return firstly {

            let worker = try self.createNewInstallingWorker(for: workerURL)
            
            return FetchOperation.fetch(workerURL)
                .then { res -> Void in
                    
                    if res.ok == false {
                        // We couldn't fetch the worker JS, so we immediately set the worker to
                        // redundant and forget about it.
                        try CoreDatabase.inConnection { db in
                            try self.updateWorkerStatus(db: db, worker: worker, newState: .redundant)
                        }
                        throw ErrorMessage("Received response code \(res.status)")
                    }
                    
                    // This promise is NOT returned, because the register() call does not
                    // wait for the worker to actually be installed - it returns as soon
                    // as the process has started.
                    _ = self.processHTTPResponse(res, newWorker: worker)
            }
            
        }
        
    }

    fileprivate func isWorkerByteIdentical(existingWorkerID: String, newHash: Data, db: SQLiteConnection) throws -> Bool {
        let existingHash = try db.select(sql: "SELECT content_hash FROM workers WHERE worker_id = ?", values: [existingWorkerID]) { resultSet -> Data in

            if resultSet.next() == false {
                throw ErrorMessage("Worker does not exist")
            }

            return try resultSet.data("content_hash")!
        }

        return existingHash == newHash
    }

    fileprivate func addResponseToWorker(_ res: FetchResponseProtocol, intoDatabase db: SQLiteConnection, withWorkerId id: String) -> Promise<Data> {

        // We can't rely on the Content-Length header as some places don't send one. But SQLite requires
        // you to establish a blob with length. So instead, we are streaming the download to disk, then
        // manually streaming into the DB when we have the length available.

        return res.internalResponse.fileDownload(withDownload: { url in

            let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = fileAttributes[.size] as! Int64

            // ISSUE: do we update the URL here, if the response was redirected? If we do, it'll mean
            // future update() calls won't check the original URL, which feels wrong. But having this
            // URL next to content from another URL also feels wrong.
            
            try db.update(sql: """
                UPDATE workers SET
                    headers = ?,
                    content = zeroblob(?)
                WHERE
                    worker_id = ?
            """, values: [
                try res.headers.toJSON(),
                size,
                id
            ])

            let rowID = try db.select(sql: "SELECT rowid FROM workers WHERE worker_id = ?", values: [id]) { rs -> Int64 in
                _ = rs.next()
                return try rs.int64("rowid")!
            }

            let inputStream = InputStream(url: url)!
            let writeStream = db.openBlobWriteStream(table: "workers", column: "content", row: rowID)

            return writeStream.pipeReadableStream(stream: ReadableStream.fromInputStream(stream: inputStream, bufferSize: 32768)) // chunks of 32KB. No idea what is best.
                .then { hash -> Data in

                    try db.update(sql: "UPDATE workers SET content_hash = ? WHERE worker_id = ?", values: [hash, id])

                    return hash
                }

        })
    }

    func processHTTPResponse(_ res: FetchResponseProtocol, newWorker: ServiceWorker, byteCompareWorker: ServiceWorker? = nil) -> Promise<Void> {

        return CoreDatabase.inConnection { db in
            self.addResponseToWorker(res, intoDatabase: db, withWorkerId: newWorker.id)
                .then { hash in

                    if byteCompareWorker != nil {
                        // In addition to HTTP headers, we also check to see if the content of the worker has
                        // changed at all. Because we're tring to save memory, we use the hash value rather than
                        // the full body.

                        if try self.isWorkerByteIdentical(existingWorkerID: byteCompareWorker!.id, newHash: hash, db: db) {

                            // Worker is identical. Delete it and stop any further operations.
                            try db.update(sql: "DELETE FROM workers WHERE worker_id = ?", values: [newWorker.id])
                            return Promise(value: ())
                        }
                    }

                   
                    return self.install(worker: newWorker, in: db)
                        .then {

                            // Workers move from installed directly to activating if they have called
                            // self.skipWaiting() OR if we have no active worker currently.

                            if newWorker.skipWaitingStatus == true || self.active == nil {
                                return self.activate(worker: newWorker, in: db)
                            } else {
                                return Promise(value: ())
                            }
                        }
                        .recover { error -> Void in

                            // If either the install or activate processes fail, we update the worker
                            // state to redundant and kill it.

                            newWorker.destroy()
                            try self.updateWorkerStatus(db: db, worker: newWorker, newState: .redundant)
                            throw error
                        }
                }
        }
    }

    fileprivate func install(worker: ServiceWorker, in db: SQLiteConnection) -> Promise<Void> {

        let ev = ExtendableEvent(type: "install")

        return firstly { () -> Promise<Void> in
            try self.updateWorkerStatus(db: db, worker: worker, newState: .installing)
            return worker.dispatchEvent(ev)
        }.then { _ in
            ev.resolve(in: worker)
        }.then {
            try self.updateWorkerStatus(db: db, worker: worker, newState: .installed)
        }
    }

    fileprivate func activate(worker: ServiceWorker, in db: SQLiteConnection) -> Promise<Void> {

        // The spec is a little weird here. A worker with the state of "activating" should go
        // into the "active" slot, but if that activation fails we'd then be left with no active
        // worker. So for the time being, we're storing a reference to the current active worker
        // (if it exists) and restoring it, if the activation fails.

        let currentActive = active

        let ev = ExtendableEvent(type: "activate")

        return firstly { () -> Promise<Void> in
            try self.updateWorkerStatus(db: db, worker: worker, newState: .activating)
            return worker.dispatchEvent(ev)
        }
        .then { _ in
            ev.resolve(in: worker)
        }
        .then {
            try self.updateWorkerStatus(db: db, worker: worker, newState: .activated)
        }
        .recover { error -> Void in
            self.active = currentActive
            throw error
        }
    }

    func clearWorkerFromAllStatuses(worker: ServiceWorker) {
        if self.active == worker {
            self.active = nil
        } else if self.waiting == worker {
            self.waiting = nil
        } else if self.installing == worker {
            self.installing = nil
        } else if self.redundant == worker {
            self.redundant = nil
        }
    }

    func updateWorkerStatus(db: SQLiteConnection, worker: ServiceWorker, newState: ServiceWorkerInstallState) throws {

        // If there's already a worker in the slot we want, we need to update its state
        var existingWorker: ServiceWorker?
        if newState == .installing {
            existingWorker = self.installing
        } else if newState == .installed {
            existingWorker = self.waiting
        } else if newState == .activating || newState == .activated {
            existingWorker = self.active
        }

        self.clearWorkerFromAllStatuses(worker: worker)
        if newState == .installing {
            self.installing = worker
        } else if newState == .installed {
            self.waiting = worker
        } else if newState == .activating || newState == .activated {
            self.active = worker
        } else if newState == .redundant {
            self.redundant = worker
        }
        
        try db.update(sql: "UPDATE workers SET install_state = ? WHERE worker_id = ?", values: [newState.rawValue, worker.id])
        worker.state = newState
        
        if existingWorker != nil && existingWorker != worker {
            // existingWorker != worker because it'll be the same worker when going from activating to activated
            try db.update(sql: "UPDATE workers SET install_state = ? WHERE worker_id = ?", values: [ServiceWorkerInstallState.redundant.rawValue, existingWorker!.id])
            existingWorker!.state = .redundant
            self.redundant = existingWorker
        }
    }

    fileprivate static let activeInstances = NSHashTable<ServiceWorkerRegistration>.weakObjects()

    public static func get(scope: URL, id: String? = nil) throws -> ServiceWorkerRegistration? {

        let active = activeInstances.allObjects.filter { $0.scope == scope }.first

        if active != nil {
            return active
        }

        return try CoreDatabase.inConnection { connection in

            var query = "SELECT * FROM registrations WHERE scope = ?"
            var values: [Any] = [scope.absoluteString]

            if let specificId = id {
                // Sometimes (usually when interfacing with the web view) we want to
                // make sure we are fetching a specific registration, which might have
                // been deleted and replaced

                query += " AND id = ?"
                values.append(specificId)
            }

            return try connection.select(sql: query, values: values) { rs -> ServiceWorkerRegistration? in

                if rs.next() == false {
                    // If we don't already have a registration, return nil (get() doesn't create one)
                    return nil
                }

                let reg = ServiceWorkerRegistration(scope: scope, id: try rs.string("id")!)

                // Need to add this now, as WorkerInstances.get() uses our static storage and
                // we don't want to get into a loop
                self.activeInstances.add(reg)

                if let activeId = try rs.string("active") {
                    reg.active = try WorkerInstances.get(id: activeId)
                }
                if let waitingId = try rs.string("waiting") {
                    reg.waiting = try WorkerInstances.get(id: waitingId)
                }
                if let installingId = try rs.string("installing") {
                    reg.installing = try WorkerInstances.get(id: installingId)
                }
                if let redundantId = try rs.string("redundant") {
                    reg.redundant = try WorkerInstances.get(id: redundantId)
                }

                return reg
            }
        }
    }

    public static func create(scope: URL) throws -> ServiceWorkerRegistration {

        return try CoreDatabase.inConnection { connection in
            let newRegID = UUID().uuidString
            _ = try connection.insert(sql: "INSERT INTO registrations (id, scope) VALUES (?, ?)", values: [newRegID, scope])
            let reg = ServiceWorkerRegistration(scope: scope, id: newRegID)
            self.activeInstances.add(reg)
            return reg
        }
    }

    public static func getOrCreate(scope: URL) throws -> ServiceWorkerRegistration {

        if let existing = try self.get(scope: scope) {
            return existing
        } else {
            return try self.create(scope: scope)
        }
    }

    public var unregistered = false

    public func unregister() -> Promise<Void> {

        return firstly {

            let allWorkers = [self.active, self.waiting, self.installing, self.redundant]

            try CoreDatabase.inConnection { db in
                try allWorkers.forEach { worker in
                    worker?.destroy()
                    if worker != nil {
                        try self.updateWorkerStatus(db: db, worker: worker!, newState: .redundant)
                    }
                }

                try db.update(sql: "DELETE FROM registrations WHERE scope = ?", values: [self.scope])
            }

            self.unregistered = true

            GlobalEventLog.notifyChange(self)

            return Promise(value: ())
        }
    }
}
