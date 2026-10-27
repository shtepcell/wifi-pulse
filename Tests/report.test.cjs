// Optional viewer tests; Node is needed only for development, not to run the app.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const html=fs.readFileSync('Sources/WifiAnalyzerCore/Resources/report.html','utf8');
const script=html.split('<script>')[1].split('const payload=')[0];
const context={window:{}};vm.createContext(context);vm.runInContext(script,context);
const {prepare,statistics,envelope}=context.window.WifiReport;
test('late reply replaces final loss while retaining late classification',()=>{
 const events=[{kind:'send',id:0,t:0},{kind:'timeout',id:0,t:1},{kind:'reply',id:0,t:1.5,latencyMS:1500,late:true},{kind:'send',id:1,t:2},{kind:'timeout',id:1,t:3},{kind:'send',id:2,t:3.1}];
 const s=statistics(prepare(events).probes);
 assert.equal(s.sent,3);assert.equal(s.missing,1);assert.equal(s.late,1);assert.equal(s.pending,1);assert.equal(s.received,1);assert.equal(s.max,1500);
});
test('pixel aggregation preserves a narrow latency spike and ignores missing data',()=>{
 const columns=envelope([{t:0,y:2},{t:.1,y:700},{t:.2,y:3},{t:.3,y:null},{t:1,y:4}],0,2,2);
 assert.equal(columns.length,2);assert.equal(columns[0].min,2);assert.equal(columns[0].max,700);assert.equal(columns[1].max,4);
});
test('empty measurements have unavailable RTT instead of zero',()=>{
 const s=statistics([]);assert.equal(s.median,null);assert.equal(s.p95,null);assert.equal(s.max,null);
});
test('nearest-rank p95 and maximum retain rare slow responses',()=>{
 const probes=Array.from({length:20},(_,i)=>({t:i,rtt:i===19?900:i+1,timedOut:false}));
 const s=statistics(probes);assert.equal(s.median,10);assert.equal(s.p95,19);assert.equal(s.max,900);
});
test('late reply is highlighted even without an earlier timeout event',()=>{
 const p=prepare([{kind:'send',id:0,t:0},{kind:'reply',id:0,t:1.1,latencyMS:1100,late:true}]).probes[0];
 assert.equal(p.timedOut,true);
});
test('missing Wi-Fi measurement explicitly breaks a rendered line',()=>{
 const cols=envelope([{t:0,y:-50},{t:1,y:null},{t:2,y:-65}],0,3,100);
 assert.equal(cols.length,2);assert.notEqual(cols[0].segment,cols[1].segment);
});
