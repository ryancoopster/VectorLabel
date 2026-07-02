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
    // QR asset label — a QR code bound to the Number field + text, on the 1.5×1.5
    // printable of Brady M6-33-427. Showcases the real barcode renderer (bwip-js).
    "asset_qr": {
      version: 1,
      name: "Asset QR V1",
      id: "A55E7A11-0000-4A11-B0DE-000000000001",
      specN: "M6-33-427",
      objs: [
        {id:"q1",t:"bc",bcType:"qrcode",eclevel:"M",mode:"field",field:"Number",x:0.12,y:0.5,w:0.62,h:0.62},
        {id:"q2",mode:"formula",t:"tx",al:"left",valign:"middle",bold:true,italic:false,underline:false,wrapText:false,autoScale:true,stretch:100,tracking:0,fs:13,font:"Arial Narrow",x:0.8,y:0.52,w:0.66,h:0.24,f:'=IF(Number<>"",Number&IF(Cable<>""," - "&Cable,""),IF(Cable<>"",Cable,""))'},
        {id:"q3",mode:"field",t:"tx",al:"left",valign:"middle",bold:false,italic:false,underline:false,wrapText:false,stretch:100,tracking:0,fs:9,font:"Arial",x:0.8,y:0.77,w:0.66,h:0.14,field:"Connector"},
        {id:"q4",t:"ln",x:0.8,y:0.95,w:0.66,h:0,lw:1},
        {id:"q5",mode:"formula",t:"tx",al:"left",valign:"middle",bold:false,italic:false,underline:false,wrapText:true,autoScale:true,stretch:100,tracking:0,fs:9,font:"Arial Narrow",x:0.8,y:0.99,w:0.66,h:0.18,f:'=IF(Device_Name<>"",Device_Name,"")'}
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
  },

  /* window.__VL_PRINTER_GEOMETRY__ for the previews — the printable-area overlay's
   * per-printer geometry, normally injected by Swift. Mirror of
   * MacApp/Sources/Core/PrinterGeometry.swift (webGeometryJSON): the default printer
   * registry + the shared Brother 128-pin/180-DPI head table. If the Swift table
   * changes, update this to match. */
  printerGeometry: (function () {
    var tapes = [
      {mm: 3.5, marginPins: 52}, {mm: 6, marginPins: 48}, {mm: 9, marginPins: 39},
      {mm: 12, marginPins: 29}, {mm: 18, marginPins: 8}, {mm: 24, marginPins: 0}
    ];
    return { models: [
      {model: "M611", kind: "brady"},
      {model: "M610", kind: "brady"},
      {model: "PT-E550W",  kind: "ptouch", dpi: 180, headPins: 128, tapes: tapes},
      {model: "PT-P750W",  kind: "ptouch", dpi: 180, headPins: 128, tapes: tapes},
      {model: "PT-E560BT", kind: "ptouch", dpi: 180, headPins: 128, tapes: tapes}
    ] };
  })(),

  /* Demo documents for the CUSTOM-mode preview (designer.html?mode=custom&doc=…):
   * a small sample data set bound to a continuous-tape design, so the support docs
   * can show the real Database pane / record browser. Sample data only — the UI
   * rendering it is the real Custom Designer front-end. */
  customDocs: {
    "asset_tags": {
      name: "Asset tags",
      specN: "M6C-2000-595",         // 2" continuous vinyl (in the front-end's fallback catalog)
      labelLengthInches: 3,
      copies: 1,
      filename: "asset-tags.csv",
      headerRow: true,
      isXLSX: false,
      columns: ["Asset", "Description", "Serial", "Location"],
      records: [
        {Asset:"AMP-01",  Description:"Stage amp rack A",     Serial:"CAS-40211", Location:"Stage left"},
        {Asset:"AMP-02",  Description:"Stage amp rack B",     Serial:"CAS-40212", Location:"Stage right"},
        {Asset:"DSP-01",  Description:"Loudspeaker DSP",      Serial:"CAS-40320", Location:"Amp room"},
        {Asset:"SW-06",   Description:"Dante network switch", Serial:"CAS-40415", Location:"FOH rack"},
        {Asset:"IO-1.01", Description:"Stage box 32×16",      Serial:"CAS-40501", Location:"Stage right"},
        {Asset:"UPS-02",  Description:"Rack UPS 1500 VA",     Serial:"CAS-40633", Location:"Amp room"}
      ],
      objs: [
        {id:"a1",t:"tx",mode:"field",field:"Asset",x:0.15,y:0.18,w:2.7,h:0.5,fs:28,font:"Arial Narrow",bold:true,italic:false,underline:false,al:"left",valign:"middle",wrapText:false,autoScale:true,stretch:100,tracking:0},
        {id:"a2",t:"ln",x:0.15,y:0.72,w:2.7,h:0,lw:2},
        {id:"a3",t:"tx",mode:"field",field:"Description",x:0.15,y:0.78,w:2.7,h:0.28,fs:14,font:"Arial",bold:false,italic:false,underline:false,al:"left",valign:"middle",wrapText:false,autoScale:true,stretch:100,tracking:0},
        {id:"a4",t:"tx",mode:"field",field:"Location",x:0.15,y:1.08,w:2.7,h:0.24,fs:12,font:"Arial",bold:false,italic:false,underline:false,al:"left",valign:"middle",wrapText:false,autoScale:true,stretch:100,tracking:0},
        {id:"a5",t:"bc",bcType:"code128",mode:"field",field:"Serial",x:0.15,y:1.4,w:1.9,h:0.42}
      ]
    }
  }
};
