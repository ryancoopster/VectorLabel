/* ─────────────────────────────────────────────────────────────────────────────
 * vl-demo.js — demo data for the website's LIVE app-HTML previews.
 *
 * The preview wrappers (print.html / designer.html) load the REAL VectorLabel
 * front-ends (embeds/print-app.html + designer-app.html, copied verbatim from
 * MacApp/Sources/Core at deploy time) and bootstrap them with the templates below
 * so the marketing site shows the actual app, rendering the actual current
 * templates, in light mode.
 *
 * These two templates mirror the shipping defaults in
 *   ~/Documents/VectorLabel/Templates/{1_5x1_5 V1,1_5x4 V1}.vltmp
 * If those templates change, update the JSON here so the previews stay honest.
 * (The records come from the app's own built-in SAMPLE_CSV, so they always match
 * whatever the current front-end ships.)
 * ─────────────────────────────────────────────────────────────────────────── */
window.VL_DEMO = {
  templates: {
    // 1.5" × 1.5" die-cut square (Brady M6-32-427)
    "1_5x1_5": {
      version: 1,
      name: "1_5x1_5 V1",
      id: "FB8C6269-85AA-4EF6-94F3-7D7E97BBDBF2",
      specN: "M6-32-427",
      objs: [
        {id:"o21",h:0.075,underline:false,tracking:0,stretch:100,mode:"field",bold:false,x:0.065,al:"left",valign:"middle",fs:8,wrapText:false,italic:false,t:"tx",font:"Arial",y:0.015,field:"Connector",w:0.8},
        {id:"o22",h:0.075,underline:false,tracking:0,stretch:100,mode:"field",bold:false,x:0.675,al:"right",valign:"middle",fs:8,wrapText:false,italic:false,t:"tx",font:"Arial",y:0.01,field:"Rack",w:0.775},
        {id:"o23",h:0.15,underline:false,tracking:0,f:'=IF(Number<>"",Number&IF(Cable<>""," - "&Cable,""),IF(Cable<>"",Cable,""))',stretch:100,mode:"formula",autoScale:true,bold:true,x:0.025,al:"center",valign:"middle",fs:12,wrapText:false,italic:false,t:"tx",font:"Arial Narrow",y:0.09,w:1.45},
        {id:"o24",x:-0.05,t:"ln",lw:2,y:0.25,h:0,w:1.6},
        {id:"o25",h:0.2,underline:false,tracking:0,f:'=IF(Device_Name<>"","@ "&Device_Name&IF(Socket_Name<>""," : "&Socket_Name,""),"")',stretch:100,mode:"formula",autoScale:true,bold:false,x:0,al:"center",valign:"middle",fs:10,wrapText:true,anchor:"mc",italic:false,t:"tx",font:"Arial Narrow",y:0.275,w:1.5}
      ]
    },
    // 1.5" × 4" self-laminating wrap (Brady M6-33-427; printable 1.5×1.5, rotates 90°)
    "1_5x4": {
      version: 1,
      name: "1_5x4 V1",
      id: "C8F9B722-9407-4679-A4EB-0CE30E5AD23E",
      specN: "M6-33-427",
      objs: [
        {id:"o46",mode:"field",wrapText:false,t:"tx",al:"left",stretch:100,bold:false,italic:false,valign:"middle",tracking:0,w:0.7,underline:false,y:0.75,fs:8,field:"Connector",x:0.05,font:"Arial",h:0.1},
        {id:"o47",mode:"field",wrapText:false,t:"tx",al:"right",stretch:100,bold:false,italic:false,valign:"middle",tracking:0,w:0.55,underline:false,y:0.75,fs:8,field:"Rack",x:0.9,font:"Arial",h:0.1},
        {id:"o48",mode:"formula",wrapText:true,t:"tx",al:"center",stretch:100,bold:true,italic:false,valign:"middle",tracking:0,w:1.45,underline:false,y:0.87,autoScale:true,fs:14,x:0.025,f:'=IF(Number<>"",Number&IF(Cable<>""," - "&Cable,""),IF(Cable<>"",Cable,""))',h:0.3,font:"Arial Narrow"},
        {id:"o49",t:"ln",x:0,lw:1,y:1.17,h:0,w:1.5},
        {id:"o50",mode:"formula",wrapText:true,t:"tx",al:"center",stretch:100,bold:false,italic:false,valign:"middle",tracking:0,w:1.45,underline:false,y:1.2,autoScale:true,fs:12,x:0.025,f:'=IF(Device_Name<>"","@ "&Device_Name&IF(Socket_Name<>""," : "&Socket_Name,""),"")',h:0.3,font:"Arial Narrow"}
      ]
    }
  }
};
