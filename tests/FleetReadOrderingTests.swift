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

// The older read reports machine "Old" and the newer "New", so any publication
// from the older read is visible in what the model saw.
let olderStarted=DispatchSemaphore(value:0)
let releaseOlder=DispatchSemaphore(value:0)
final class ReadModel {
 var newerStarted=false
 var observations:[[String:Any]]=[]
 var fleet: FleetData? {didSet {
  precondition(Thread.isMainThread)
  let f=fleet!
  if f.machine=="New" || f.readError != nil { newerStarted=true }
  precondition(!newerStarted || f.machine != "Old", "obsolete read published after a newer one")
  observations.append(["machine":f.machine,"states":f.tasks.map{$0.state.rawValue},"error":f.readError as Any? ?? NSNull()])
  // The older read finishes only after the newer one has published everything.
  if newerStarted && f.loading.isEmpty { releaseOlder.signal() }
 }}
}
final class AppDelegate {
 var fleetReadID: UUID?
 let model=ReadModel()
 let lock=NSLock()
 var statusCalls=0
 var taskCalls=0
 var announcements=0
 var attention=0
 let scenario=CommandLine.arguments[1]
 func runCLI(_ args:[String], timeout: TimeInterval? = nil)->(status:Int32,output:String){
  let command=args.dropFirst().joined(separator:" ")
  if command=="status --no-probe" {
   lock.lock();statusCalls+=1;let request=statusCalls;lock.unlock()
   if request==1 && scenario != "older-sections" {olderStarted.signal();releaseOlder.wait()}
   if (request==1 && scenario=="older-failure") || (request==2 && scenario=="newer-failure") {return (1,"")}
   return (0,"self\t"+(request==1 ? "Old" : "New")+"\tself-id\n")
  }
  if command=="task list" {
   lock.lock();taskCalls+=1;let call=taskCalls;lock.unlock()
   let older=call==1 && scenario=="older-sections"
   if older {olderStarted.signal();releaseOlder.wait()}
   return (0,"task-1\t"+(older ? "running" : "completed")+"\tcodex\t0\tWork\tPeer\tdispatcher\n")
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
  DispatchQueue.main.async { app.refreshFleet() }
  Dispatch.DispatchQueue.global().async {
   olderStarted.wait()
   Dispatch.DispatchQueue.main.async {
    app.refreshFleet()
    DispatchQueue.group.notify(queue:.main){
     let value = app.model.fleet!
     precondition(app.attention == app.model.observations.count, "every publication updates attention once")
     if app.scenario == "newer-failure" {
      precondition(value.readError != nil && value.tasks.isEmpty && value.observedAt == nil)
      precondition(app.announcements == 0)
     } else {
      precondition(value.readError == nil && value.machine == "New" && value.tasks.first?.state == .done)
      precondition(value.observedAt != nil && value.loading.isEmpty)
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
