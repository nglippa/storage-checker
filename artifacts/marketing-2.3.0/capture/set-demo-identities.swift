import Foundation
import SQLite3
import Darwin

// Materialize empty demo placeholders only, so Inspector identity checks describe the fixture correctly.
// Displayed historical measurements remain fictional marketing data; no large file is allocated.
let database=CommandLine.arguments[1]
let root="/private/tmp/Storage Monitor Demo 230"
var db:OpaquePointer?
precondition(sqlite3_open(database,&db)==SQLITE_OK)
let transient=unsafeBitCast(-1,to:sqlite3_destructor_type.self)
var statement:OpaquePointer?
sqlite3_prepare_v2(db,"SELECT id,parent_id,name,kind,object_id FROM inventory_nodes ORDER BY id",-1,&statement,nil)
var paths=[Int64:String]()
var values=[(Int64,UInt64,Int64,Int64)]()
while sqlite3_step(statement)==SQLITE_ROW {
 let id=sqlite3_column_int64(statement,0),parent=sqlite3_column_int64(statement,1)
 let name=String(cString:sqlite3_column_text(statement,2)),kind=String(cString:sqlite3_column_text(statement,3))
 let path=sqlite3_column_type(statement,1)==SQLITE_NULL ? root : paths[parent]!+"/"+name
 paths[id]=path
 if kind=="directory" { try! FileManager.default.createDirectory(atPath:path,withIntermediateDirectories:true) }
 else if !FileManager.default.fileExists(atPath:path) { FileManager.default.createFile(atPath:path,contents:Data()) }
 var st=stat(); precondition(lstat(path,&st)==0)
 values.append((sqlite3_column_int64(statement,4),st.st_ino,Int64(st.st_dev),Int64(st.st_birthtimespec.tv_sec)*1_000_000_000+Int64(st.st_birthtimespec.tv_nsec)))
}
sqlite3_finalize(statement)
for (object,inode,device,birth) in values {
 sqlite3_prepare_v2(db,"UPDATE inventory_objects SET device=?,inode=?,birth_ns=? WHERE id=?",-1,&statement,nil)
 sqlite3_bind_int64(statement,1,device); sqlite3_bind_int64(statement,2,Int64(inode)); sqlite3_bind_int64(statement,3,birth); sqlite3_bind_int64(statement,4,object)
 precondition(sqlite3_step(statement)==SQLITE_DONE); sqlite3_finalize(statement)
}
let identity=values.first!
sqlite3_prepare_v2(db,"UPDATE inventory_generations SET root_path=?,root_device=?,root_inode=?,root_birth_ns=? WHERE id=1",-1,&statement,nil)
sqlite3_bind_text(statement,1,root,-1,transient); sqlite3_bind_int64(statement,2,identity.2); sqlite3_bind_int64(statement,3,Int64(identity.1)); sqlite3_bind_int64(statement,4,identity.3)
precondition(sqlite3_step(statement)==SQLITE_DONE); sqlite3_finalize(statement); sqlite3_close(db)
print("PASS: \(values.count) demo placeholders have real fixture identities; displayed sizes are fictional.")
