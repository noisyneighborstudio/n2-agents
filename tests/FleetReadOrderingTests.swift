import Foundation
import Dispatch

// Track real queue blocks, including nested publication, before observing state.
struct DispatchQueue {
    static let group = DispatchGroup()
    let queue: Dispatch.DispatchQueue
    static func global(qos: DispatchQoS.QoSClass) -> Self { Self(queue: .global(qos: qos)) }
    static var main: Self { Self(queue: .main) }
    func async(execute body: @escaping () -> Void) {
        Self.group.enter()
        queue.async { body(); Self.group.leave() }
    }
}

let firstStarted=DispatchSemaphore(value:0)
let releaseFirst=DispatchSemaphore(value:0)
final class ReadModel {
 var firstPublished: FleetData?
 var observations:[[String:Any]]=[]
 var fleet: FleetData? {didSet {
  precondition(Thread.isMainThread)
  if firstPublished == nil { firstPublished = fleet }
  observations.append(["states":fleet!.tasks.map{$0.state.rawValue},"error":fleet!.readError as Any? ?? NSNull()])
  releaseFirst.signal()
 }}
}
final class AppDelegate {
 var fleetReadID: UUID?
 let model=ReadModel()
 let lock=NSLock()
 var calls=0
 var announcements=0
 var attention=0
 let scenario=CommandLine.arguments[1]
 func runCLI(_ args:[String])->(status:Int32,output:String){
  let command=args.dropFirst().joined(separator:" ")
  if command=="status --no-probe" {
   lock.lock();calls+=1;let request=calls;lock.unlock()
   Thread.current.threadDictionary["request"]=request
   if request==1 {firstStarted.signal();releaseFirst.wait()}
   if (request==1 && scenario=="older-failure") || (request==2 && scenario=="newer-failure") {return (1,"")}
   return (0,"self\tFixture\tself-id\n")
  }
  if command=="task list" {
   let request=Thread.current.threadDictionary["request"] as! Int
   return (0,"task-1\t"+(request==1 ? "running" : "completed")+"\tcodex\t0\tWork\tPeer\tdispatcher\n")
  }
  return (0,"")
 }
 func announce(_ notices:[FleetNotice]){announcements+=1}
 func updateFleetAttention(_ data:FleetData){attention+=1}
    // PRODUCTION_METHODS
}
@main struct Proof {
 static let app=AppDelegate()
 static func main(){
  DispatchQueue.global(qos: .utility).async { app.refreshFleet() }
  Dispatch.DispatchQueue.global().async {
   firstStarted.wait()
   Dispatch.DispatchQueue.main.async {
    app.refreshFleet()
    DispatchQueue.group.notify(queue:.main){
     precondition(app.model.observations.count == 1, "obsolete read published")
     precondition(app.attention == 1, "obsolete read changed attention")
     let value = app.model.fleet!
     precondition(value.observedAt == app.model.firstPublished!.observedAt, "obsolete read changed timestamp")
     if app.scenario == "newer-failure" {
      precondition(value.readError != nil && value.tasks.isEmpty && value.observedAt == nil)
      precondition(app.announcements == 0)
     } else {
      precondition(value.readError == nil && value.tasks.first?.state == .done && value.observedAt != nil)
      precondition(app.announcements == 1)
     }
     let output:[String:Any]=["scenario":app.scenario,"publications":app.model.observations,"announcements":app.announcements]
     let data=try! JSONSerialization.data(withJSONObject:output,options:[.sortedKeys])
     print(String(decoding:data,as:UTF8.self));exit(0)
    }
   }
  }
  RunLoop.main.run()
 }
}
