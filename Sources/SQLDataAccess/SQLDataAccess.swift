//
//  SQLDataAccess.swift
//  SQLPackage
//
//  Created by Pat Murphy on 10/14/17.
//  The MIT License (MIT)
//

import Foundation
import Willow
import SQLite3

//Constants
let SQL             = "SQL"
let PARAMS          = "PARAMS"

public class SQLDataAccess: NSObject {
    
    static let shared = SQLDataAccess()
    var DB_FILE = "SQLite.db"
    private var path:String!
    private let DB_Queue = "SQLiteQueue"
    private var queue:DispatchQueue!
    private var sqlite3dbConn:OpaquePointer? = nil
    private let db_format = DateFormatter()
    private let SQLITE_DATE = SQLITE_NULL + 1
    private let SQLITE_STATIC = unsafeBitCast(0, to:sqlite3_destructor_type.self)
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to:sqlite3_destructor_type.self)
    private let EN_KEY = "45763887E33478287EFFEB42890CD1EF"
    //private var logger = Logger(label: "DA")

    var log: Logger
    {
        let queue = DispatchQueue(label: "serial.queue", qos: .utility)
        var logger = Logger(logLevels: [.all], writers: [ConsoleWriter()], executionMethod: .asynchronous(queue: queue))
        logger.enabled = true
        return logger
    }
    
    public override init() {
        super.init()
        queue = DispatchQueue(label:DB_Queue, attributes:[])
        //for 24-hour format need locale to work, ISO-8601 format
        db_format.locale = Locale(identifier:"en_US_POSIX")
        db_format.timeZone = TimeZone(secondsFromGMT:0)
        db_format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        //logger.logLevel = .debug
    }
    
    deinit {
        closeConnection()
    }
    
    @objc public func getDBName() -> String
    {
        return DB_FILE
    }
    
    public func setDBName(name:String)
    {
        DB_FILE = name
    }
    
    public func closeConnection()
    {
        var rc = sqlite3_close(sqlite3dbConn)
        if(rc == SQLITE_BUSY)
        {
            let ps:OpaquePointer? = nil
            var stmt = sqlite3_next_stmt(sqlite3dbConn, ps)
            while (stmt != nil)
            {
                stmt = sqlite3_next_stmt(sqlite3dbConn, ps)
                sqlite3_finalize(stmt)
            }
            rc = sqlite3_close(sqlite3dbConn)
            if(rc == SQLITE_OK)
            {
                log.debugMessage("DA : DB : CLOSED")
            }
            else if(rc == SQLITE_BUSY)
            {
                log.debugMessage("DA : DB : BUSY CLOSED")
                sqlite3_finalize(stmt);
            }
        }
        sqlite3dbConn = nil;
    }
    
    public override var description:String {
        return "DA : DB path \(path!)"
    }
    
    public func dbDateStr(date:Date) -> String {
        return db_format.string(from:date)
    }
    
    public func dbStrDate(date:String) -> Date {
        return db_format.date(from:date)!
    }

    public func openConnection(copyFile:Bool = true) -> Bool {
        
        if(sqlite3dbConn != nil)
        {
            log.debugMessage("DA : DB : OPENED")
            return true
        }
        else
        {
            log.debugMessage("DA : DB : OPENING")
        }
        let fm = FileManager.default
        let docDir = NSSearchPathForDirectoriesInDomains(FileManager.SearchPathDirectory.documentDirectory, FileManager.SearchPathDomainMask.userDomainMask, true)[0]
        let path = (docDir as NSString).appendingPathComponent(DB_FILE)
        // Check if DB is there in Documents directory
        if !(fm.fileExists(atPath:path)) && copyFile {
            // The database does not exist, so copy it
            guard let rp = Bundle.main.resourcePath else { return false }
            let from = (rp as NSString).appendingPathComponent(DB_FILE)
            do {
                try fm.copyItem(atPath:from, toPath:path)

            } catch let error {
                assert(false, "DA : Failed to copy writable version of \(DB_FILE)! Error - \(error.localizedDescription)")
                return false
            }
        }
        // Open the DB
        let cpath = path.cString(using:String.Encoding.utf8)
        let error = sqlite3_open(cpath!, &sqlite3dbConn)
        if error != SQLITE_OK {
            // Open failed, close DB and fail
            log.errorMessage("DA - failed to open \(DB_FILE)!")
            sqlite3_close(sqlite3dbConn)
            return false
        }
        else
        {
            log.debugMessage("DA : \(DB_FILE) opened : path = \(path)")
        }
        
        return true
    }
    
    public func foreignKeys(_ enable:Bool)
    {   var sql = String()
        if(enable)
        {
            sql = String(format:"PRAGMA foreign_keys = ON;")
        }
        else
        {
            sql = String(format:"PRAGMA foreign_keys = OFF;")
        }
        sqlite3_exec(sqlite3dbConn, sql, nil, nil, nil);
        let errCode = Int(sqlite3_errcode(sqlite3dbConn))
        if(errCode != SQLITE_OK)
        {
            let errMsg = String(validatingUTF8:sqlite3_errmsg(sqlite3dbConn))
            log.errorMessage("DA : foreignKeys : sqlErrCode = \(errCode) : sqlErrMsg = \(errMsg!)")
        }
    }
    
    public func dbEncrypt(_ key:String)
    {
        let sql1 = String(format:"ft67s%@58uy%@fge4",EN_KEY,key)
        #if ENCRYPT
            //This method only exists in SQLCipher
            sqlite3_key(sqlite3dbConn,sql1,Int(strlen(sql1)))
        #endif
        let sql2 = String(format:"PRAGMA cipher = 'aes-256-cfb';")
        sqlite3_exec(sqlite3dbConn, sql2, nil, nil, nil);
        let errCode = Int(sqlite3_errcode(sqlite3dbConn))
        if(errCode != SQLITE_OK)
        {
            let errMsg = String(validatingUTF8:sqlite3_errmsg(sqlite3dbConn))
            log.errorMessage("DA : ENCRYPT : sqlErrCode = \(errCode) : sqlErrMsg = \(errMsg!)")
        }
    }
    
    public func dbDecrypt()
    {
        copyDBtoDocumentDirectory(copyDBFile: DB_FILE, toDBFile: DB_FILE+"X")
        let dbFileX = pathForFileWithName(fileName: DB_FILE+"X")
        let sql1 = String(format:"attach database '%@' as plaintext KEY '';",dbFileX)
        sqlite3_exec(sqlite3dbConn, sql1, nil, nil, nil)
        
        let sql2 = String(format:"select sqlcipher_export('plaintext');")
        sqlite3_exec(sqlite3dbConn, sql2, nil, nil, nil)
        
        let sql3 = String(format:"detach database plaintext;")
        sqlite3_exec(sqlite3dbConn, sql3, nil, nil, nil)
        let errCode = Int(sqlite3_errcode(sqlite3dbConn))
        if(errCode != SQLITE_OK)
        {
            let errMsg = String(validatingUTF8:sqlite3_errmsg(sqlite3dbConn))
            log.errorMessage("DA : DECRYPT : sqlErrCode = \(errCode) : sqlErrMsg = \(errMsg!)")
        }
        replaceDBinDocumentDirectory(removeDBFile: DB_FILE, renameDBFile: DB_FILE+"X")
        let path = pathForFileWithName(fileName: DB_FILE)
        // Open the DB
        let cpath = path.cString(using:String.Encoding.utf8)
        let error = sqlite3_open(cpath!, &sqlite3dbConn)
        if error != SQLITE_OK {
            // Open failed, close DB and fail
            log.errorMessage("DA - failed to open \(DB_FILE)!")
            sqlite3_close(sqlite3dbConn)
        }
        else
        {
            log.debugMessage("DA : \(DB_FILE) opened : path = \(path)")
        }
        
    }
    
    private func stmt(_ ps: inout OpaquePointer!, forQuery query: String, withParams parameters: Array<Any>!) -> OpaquePointer! {
        
        if(sqlite3dbConn == nil)
        {
            return nil
        }
        //Use inout ps pointer so return can hit sqlite3_finalize
        var code:Int32 = -1
        
        //Do sanity check on query first to make sure it's Ok
        if let cSql = query.cString(using: String.Encoding.utf8) {
            code = sqlite3_prepare_v2(sqlite3dbConn, cSql, CInt(query.lengthOfBytes(using: String.Encoding.utf8)), &ps, nil)
        }
        
        if(code == SQLITE_OK)
        {
            var flag:CInt = 0
            for i in 0 ..< parameters.count {
                
                if let val = parameters![i] as? Double {
                    flag = sqlite3_bind_double(ps, CInt(i+1), CDouble(val))
                }
                else if let val = parameters![i] as? Float {
                    flag = sqlite3_bind_double(ps, CInt(i+1), Double(CFloat(val)))
                }
                else if let val = parameters![i] as? Int64 {
                    flag = sqlite3_bind_int64(ps, CInt(i+1), CLongLong(val))
                }
                else if let val = parameters![i] as? Int {
                    flag = sqlite3_bind_int(ps, CInt(i+1), CInt(val))
                }
                else if let val = parameters![i] as? Bool {
                    let num = val ? 1 : 0
                    flag = sqlite3_bind_int(ps, CInt(i+1), CInt(num))
                }
                else if let txt = parameters![i] as? String {
                    flag = sqlite3_bind_text(ps, CInt(i+1), txt, -1, SQLITE_TRANSIENT)
                }
                else if let date = parameters![i] as? Date {
                    let dateStr = self.dbDateStr(date: date)
                    flag = sqlite3_bind_text(ps, CInt(i+1), dateStr, -1, SQLITE_TRANSIENT)
                }
                else if let dataValue = parameters![i] as? NSData {
                    flag = sqlite3_bind_blob(ps, CInt(i+1), dataValue.bytes, CInt(dataValue.length), SQLITE_TRANSIENT)
                }
                else if parameters![i] is NSNull {
                    flag = sqlite3_bind_null(ps,CInt(i+1));
                }
                else
                {
                    log.errorMessage("DA : SQL Error Stmt No match found for Data Type")
                }
                
                if flag != SQLITE_OK {
                    let errMsg = String(validatingUTF8:sqlite3_errmsg(sqlite3dbConn))
                    let errCode = Int(sqlite3_errcode(sqlite3dbConn))
                    log.errorMessage("DA : SQL Error bind Stmt : Err[\(errCode)] = \(String(describing: errMsg!)) : Q = \(query)\n");
                }
            }
        }
        else
        {
            let errMsg = String(validatingUTF8:sqlite3_errmsg(sqlite3dbConn))
            let errCode = Int(sqlite3_errcode(sqlite3dbConn))
            log.errorMessage("DA : SQL Error prepared Stmt : Err[\(errCode)] = \(String(describing: errMsg!)) : Q = \(query)\n");
        }
        
        return ps
    }

    @discardableResult public func executeStatement(_ query: String!, _ args:Any...) -> Bool {
        
        var status : Bool = false
        if(sqlite3dbConn == nil)
        {
            return false
        }
        
        status = self.executeStatement(query, withParams: args)
        return status
    }
    
    @discardableResult public func executeStatement(_ query: String, withParams parameters: Array<Any>!) -> Bool {
        
        var status : Bool = false
        
        if(sqlite3dbConn == nil)
        {
            return status
        }
        
        queue.sync {
            //Synchronize all accesses
            var ps:OpaquePointer? = nil
            
            if let ps = self.stmt(&ps, forQuery:query, withParams:parameters) {
                let code = sqlite3_step(ps)
                if(code == SQLITE_DONE)
                {
                    status = true
                }
                else
                {
                    status = false
                }
                
                if( !status )
                {
                    let errMsg = String(validatingUTF8:sqlite3_errmsg(sqlite3dbConn))
                    let errCode = Int(sqlite3_errcode(sqlite3dbConn))
                    log.errorMessage("DA : SQL Error during execute : Err[\(errCode)] = \(String(describing: errMsg!)) : Q = \(query)\n");
                }
            }
            sqlite3_finalize(ps)
            sqlite3_exec(sqlite3dbConn, "COMMIT TRANSACTION", nil, nil, nil)
        }
        return status //queue.sync {status}
    }

    public func getRecordsForQuery(_ query: String!, _ args:Any...) -> Array<Any> {
        
        var results = [Any]()
        if(sqlite3dbConn == nil)
        {
            return results
        }
        
        results = self.getRecordsForQuery(query, withParams: args)
        return results
    }

    private func getColumnType(_ ps:OpaquePointer,_ index:CInt)->CInt {
        var type:CInt = 0
        // Column types - http://www.sqlite.org/datatype3.html (section 2.2 table column 1)
        let blobTypes = ["BINARY", "BLOB", "VARBINARY"]
        let charTypes = ["CHAR", "CHARACTER", "CLOB", "NATIONAL VARYING CHARACTER", "NATIVE CHARACTER", "NCHAR", "NVARCHAR", "TEXT", "VARCHAR", "VARIANT", "VARYING CHARACTER"]
        let dateTypes = ["DATE", "DATETIME", "TIME", "TIMESTAMP"]
        let intTypes  = ["BIGINT", "BIT", "BOOL", "BOOLEAN", "INT", "INT2", "INT8", "INTEGER", "MEDIUMINT", "SMALLINT", "TINYINT"]
        let nullTypes = ["NULL"]
        let realTypes = ["DECIMAL", "DOUBLE", "DOUBLE PRECISION", "FLOAT", "CGFLOAT", "NUMERIC", "REAL"]
        // Determine type of column - http://www.sqlite.org/c3ref/c_blob.html
        let buf = sqlite3_column_decltype(ps, index)
        if buf != nil {
            var tmp = String(validatingUTF8:buf!)!.uppercased()
            if let pos = tmp.range(of:"(") {
                tmp = String(tmp[..<pos.lowerBound])
                //tmp = tmp.substring(to:pos.lowerBound)
            }
            if intTypes.contains(tmp) {
                return SQLITE_INTEGER
            }
            if realTypes.contains(tmp) {
                return SQLITE_FLOAT
            }
            if charTypes.contains(tmp) {
                return SQLITE_TEXT
            }
            if blobTypes.contains(tmp) {
                return SQLITE_BLOB
            }
            if nullTypes.contains(tmp) {
                return SQLITE_NULL
            }
            if dateTypes.contains(tmp) {
                return SQLITE_DATE
            }
            //If none of the above has to be text
            return SQLITE_TEXT
        } else {
            // For expressions and sub-queries
            type = sqlite3_column_type(ps, index)
        }
        return type
    }
    
    public func getRecordsForQuery(_ query: String!, withParams parameters: Array<Any>!) -> Array<[String:Any]> {
        //Returns an Array of Dictionaries
        var results = [[String:Any]]()

        if(sqlite3dbConn == nil)
        {
            return results
        }
        queue.sync {

            //Synchronize all accesses
            var ps:OpaquePointer? = nil
            if let ps = self.stmt(&ps, forQuery:query, withParams:parameters)
            {
                let columnCount = sqlite3_column_count(ps)
                var result = Dictionary<String,AnyObject>()
                while sqlite3_step(ps) == SQLITE_ROW
                {
                    for i in 0..<columnCount
                    {
                        let columnType = self.getColumnType(ps,i)
                        let name = sqlite3_column_name(ps,i)
                        switch columnType {
                        case SQLITE_INTEGER:
                            result[String(validatingUTF8: name!)!] = Int64(sqlite3_column_int64(ps,i)) as AnyObject?
                        case SQLITE_FLOAT:
                            result[String(validatingUTF8: name!)!] = Double(sqlite3_column_double(ps,i)) as AnyObject?
                        case SQLITE_TEXT:
                            if let ptr = UnsafeRawPointer.init(sqlite3_column_text(ps,i)) {
                                let uptr = ptr.bindMemory(to:CChar.self, capacity:0)
                                result[String(validatingUTF8: name!)!] = String(validatingUTF8:uptr) as AnyObject?
                            }
                        case SQLITE_BLOB:
                            result[String(validatingUTF8: name!)!] = NSData(bytes:sqlite3_column_blob(ps,i), length:Int(sqlite3_column_bytes(ps,i))) as AnyObject?
                        case SQLITE_NULL:
                            result[String(validatingUTF8: name!)!] = String(validatingUTF8:"") as AnyObject?
                        case SQLITE_DATE:
                            //Our defined DATE
                            if let ptr = UnsafeRawPointer.init(sqlite3_column_text(ps,i)) {
                                let uptr = ptr.bindMemory(to:CChar.self, capacity:0)
                                let dateStr = String(validatingUTF8:uptr)
                                let set = CharacterSet(charactersIn:"-:")
                                if dateStr?.rangeOfCharacter(from:set) != nil {
                                    // Convert to time
                                    var time:tm = tm(tm_sec: 0, tm_min: 0, tm_hour: 0, tm_mday: 0, tm_mon: 0, tm_year: 0, tm_wday: 0, tm_yday: 0, tm_isdst: 0, tm_gmtoff: 0, tm_zone:nil)
                                    strptime(dateStr, "%Y-%m-%d %H:%M:%S", &time)
                                    time.tm_isdst = -1
                                    let diff = TimeZone.current.secondsFromGMT()
                                    let t = mktime(&time) + diff
                                    let ti = TimeInterval(t)
                                    let date = Date(timeIntervalSince1970:ti)
                                    result[String(validatingUTF8: name!)!] = date as AnyObject?
                                }
                                else
                                {
                                    log.errorMessage("DA : SQL Error getRecords Invalid Date ")
                                }
                            }
                        default:
                            log.errorMessage("DA : SQL Error getRecords Invalid column type")
                        }
                    }
                    results.append(result)
                }
            }
            else
            {
                let errMsg = String(validatingUTF8:sqlite3_errmsg(sqlite3dbConn))
                let errCode = Int(sqlite3_errcode(sqlite3dbConn))
                log.errorMessage("DA : SQL Error getRecords : Err[\(errCode)] = \(String(describing: errMsg!)) : Q = \(query!)\n");
            }
            sqlite3_finalize(ps)
        }
        return results //queue.sync {results}
    }
    
    @discardableResult public func executeTransaction(_ sqlAndParamsForTransaction: Array<[String:Any]>!) -> Bool {
        
        var status : Bool = true
        
        if(sqlite3dbConn == nil)
        {
            return status
        }
        
        queue.sync {
            //Synchronize all accesses
            for i in 0..<sqlAndParamsForTransaction.count {

                var ps:OpaquePointer? = nil
                sqlite3_exec(sqlite3dbConn, "BEGIN EXCLUSIVE TRANSACTION", nil, nil, nil)
                let query = sqlAndParamsForTransaction[i][SQL] as! String
                let parameters = sqlAndParamsForTransaction[i][PARAMS] as! Array<Any>

                if let ps = self.stmt(&ps, forQuery:query, withParams:parameters) {
                    let code = sqlite3_step(ps)
                    if(code == SQLITE_DONE)
                    {
                        status = true
                    }
                    else
                    {
                        status = false
                    }
                    
                    if( !status )
                    {
                        let errMsg = String(validatingUTF8:sqlite3_errmsg(sqlite3dbConn))
                        let errCode = Int(sqlite3_errcode(sqlite3dbConn))
                        log.errorMessage("DA : SQL Error during executeTransaction : Err[\(errCode)] = \(String(describing: errMsg!)) : Q = \(query)\n");
                        sqlite3_exec(sqlite3dbConn, "ROLLBACK", nil, nil, nil)
                    }
                }
                sqlite3_finalize(ps)
                sqlite3_exec(sqlite3dbConn, "COMMIT TRANSACTION", nil, nil, nil)
            }
        }
        return status
    }
    
    @discardableResult func copyDBtoDocumentDirectory(copyDBFile:String, toDBFile:String) -> Bool
    {
        var status:Bool = false
        let fm = FileManager.default
        let docDir = NSSearchPathForDirectoriesInDomains(FileManager.SearchPathDirectory.documentDirectory, FileManager.SearchPathDomainMask.userDomainMask, true)[0]
        let copyDBPath = (docDir as NSString).appendingPathComponent(copyDBFile)
        let toDBPath = (docDir as NSString).appendingPathComponent(toDBFile)
        
        if !(fm.fileExists(atPath:copyDBPath)) {
            do {
                try fm.copyItem(atPath:copyDBPath, toPath:toDBPath)
                status = true
            } catch let error {
                assert(false, "DA : copyDB : Failed to copy file \(copyDBPath) to \(toDBPath) Error - \(error.localizedDescription)")
                status = false
            }
        }
        return status
    }
    
    func pathForFileWithName(fileName:String) -> String
    {
        let fm = FileManager.default
        let docDir = NSSearchPathForDirectoriesInDomains(FileManager.SearchPathDirectory.documentDirectory, FileManager.SearchPathDomainMask.userDomainMask, true)[0]
        let path = (docDir as NSString).appendingPathComponent(fileName)
        if (fm.fileExists(atPath:path))  {
            var url = NSURL.fileURL(withPath: docDir)
            url.setTemporaryResourceValue(NSNumber(value:true), forKey: URLResourceKey.isExcludedFromBackupKey)
            return path
        }
        else
        {
            assert(false, "DM : pathFor : Path for file \(fileName)! Not Found ")
            return ""
        }
    }
    
    @discardableResult func replaceDBinDocumentDirectory(removeDBFile:String, renameDBFile:String) -> Bool
    {
        var status:Bool = false
        let fm = FileManager.default
        let docDir = NSSearchPathForDirectoriesInDomains(FileManager.SearchPathDirectory.documentDirectory, FileManager.SearchPathDomainMask.userDomainMask, true)[0]
        let removeDBPath = (docDir as NSString).appendingPathComponent(removeDBFile)
        let renameDBPath = (docDir as NSString).appendingPathComponent(renameDBFile)
        
        do {
            try fm.removeItem(atPath: removeDBPath)
            status = true
        } catch let error {
            assert(false, "DM : replaceDB : Failed to remove file \(removeDBFile)! Error - \(error.localizedDescription)")
            status = false
            return status
        }
        
        do {
            try fm.moveItem(atPath: renameDBPath, toPath: removeDBPath)
            status = true
        } catch let error {
            assert(false, "DM : replaceDB : Failed to move file \(renameDBFile)! Error - \(error.localizedDescription)")
            status = false
            return status
        }
        
        if !(fm.fileExists(atPath:removeDBPath)) {
            assert(false, "DA : replaceDB : Failed to replace file \(removeDBFile) with \(renameDBFile) Error ")
            status = false
        }
        return status
    }
}
