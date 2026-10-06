"use client";

import React from "react";
import { motion } from "framer-motion";

export default function SavoraAppScreens() {
  return (
    <section id="app-preview" className="savora-section relative overflow-hidden py-24 sm:py-32 bg-[#FBF6EE]">
      <style dangerouslySetInnerHTML={{ __html: `
        .savora-wrap {
          --oat: #F1E8DA; --canvas: #F6EFE4; --cream: #FDFAF4;
          --roast: #352A22; --roast-soft: #6E5C4E;
          --caramel: #C77B43; --honey: #E9B85C; --sage: #9DB089; --sage-deep: #6F8466;
          --paprika: #D86A4B; --line: #E6DACA;
          font-family: 'Figtree', sans-serif;
          color: var(--roast);
          background: radial-gradient(1300px 800px at 50% -10%, #FBF6EE 0%, var(--oat) 55%, #EBE0CF 100%);
          width: 100%;
          padding: 54px 20px 70px;
        }
        .savora-wrap .deck-head { text-align: center; margin-bottom: 46px; }
        .savora-wrap .eyebrow { font-size: 12px; letter-spacing: .32em; text-transform: uppercase; color: var(--caramel); font-weight: 600; margin-bottom: 14px; }
        .savora-wrap .deck-head h2 { font-family: 'Fraunces', serif; font-weight: 500; font-size: clamp(32px, 5vw, 52px); line-height: 1.04; letter-spacing: -.01em; }
        .savora-wrap .deck-head h2 em { font-style: italic; color: var(--caramel); }
        .savora-wrap .deck-head p { margin: 14px auto 0; max-width: 540px; color: var(--roast-soft); font-size: 15.5px; line-height: 1.55; }
        
        .savora-wrap .phones { display: flex; gap: 38px 34px; justify-content: center; align-items: flex-start; flex-wrap: wrap; }
        .savora-wrap .phone-col { display: flex; flex-direction: column; align-items: center; gap: 16px; width: 312px; }
        .savora-wrap .phone-cap { font-size: 13px; color: var(--roast-soft); text-align: center; }
        .savora-wrap .phone-cap b { color: var(--roast); font-weight: 600; }
        
        .savora-wrap .phone { width: 312px; height: 660px; border-radius: 46px; background: #211a14; padding: 11px; box-shadow: 0 40px 80px -30px rgba(53,42,34,.5), 0 12px 30px -12px rgba(53,42,34,.3); position: relative; flex: none; }
        .savora-wrap .screen { width: 100%; height: 100%; border-radius: 36px; overflow: hidden; background: var(--canvas); position: relative; display: flex; flex-direction: column; }
        .savora-wrap .notch { position: absolute; top: 11px; left: 50%; transform: translateX(-50%); width: 104px; height: 26px; background: #211a14; border-radius: 0 0 16px 16px; z-index: 30; }
        .savora-wrap .statusbar { display: flex; justify-content: space-between; align-items: center; padding: 13px 24px 4px; font-size: 12px; font-weight: 600; z-index: 20; color: var(--roast); }
        .savora-wrap .statusbar .dots { display: flex; gap: 6px; align-items: center; }
        .savora-wrap .bat { width: 20px; height: 11px; border: 1.4px solid var(--roast); border-radius: 3px; position: relative; opacity: .85; }
        .savora-wrap .bat::after { content: ""; position: absolute; right: -3px; top: 3px; width: 2px; height: 5px; background: var(--roast); border-radius: 1px; }
        .savora-wrap .bat i { position: absolute; left: 1.5px; top: 1.5px; bottom: 1.5px; width: 65%; background: var(--roast); border-radius: 1px; }
        .savora-wrap .body { flex: 1; overflow: hidden; padding: 8px 20px 0; display: flex; flex-direction: column; }
        
        .savora-wrap .ttl-lg { font-family: 'Fraunces', serif; font-size: 24px; font-weight: 500; line-height: 1.1; color: var(--roast); }
        .savora-wrap .sub-sm { font-size: 12.5px; color: var(--roast-soft); margin-top: 3px; }
        .savora-wrap .back { width: 34px; height: 34px; border-radius: 50%; background: var(--cream); border: 1px solid var(--line); display: flex; align-items: center; justify-content: center; flex: none; }
        .savora-wrap .row-head { display: flex; align-items: center; gap: 12px; margin-top: 6px; }
        
        .savora-wrap .btn-pri { display: flex; align-items: center; justify-content: center; gap: 9px; background: var(--roast); color: #FCF3E6; border: none; border-radius: 20px; padding: 16px; font-family: 'Figtree'; font-size: 15px; font-weight: 600; width: 100%; cursor: pointer; box-shadow: 0 14px 24px -12px rgba(53,42,34,.55); }
        .savora-wrap .btn-ghost { background: none; border: none; color: var(--roast-soft); font-family: 'Figtree'; font-weight: 600; font-size: 14px; padding: 12px; width: 100%; cursor: pointer; }
        
        .savora-wrap .ob { background: linear-gradient(180deg,#FBF5EB 0%,#F2E6D2 100%); align-items: center; text-align: center; }
        .savora-wrap .ob-art { margin: 30px 0 8px; position: relative; }
        .savora-wrap .ob-tag { font-family: 'Fraunces', serif; font-style: italic; font-size: 13px; color: var(--caramel); letter-spacing: .05em; }
        .savora-wrap .ob h3 { font-family: 'Fraunces', serif; font-size: 34px; font-weight: 500; line-height: 1.08; margin-top: 8px; color: var(--roast); }
        .savora-wrap .ob p { font-size: 13.5px; color: var(--roast-soft); line-height: 1.55; margin-top: 12px; max-width: 240px; }
        .savora-wrap .dots-prog { display: flex; gap: 7px; justify-content: center; margin: 22px 0; }
        .savora-wrap .dots-prog i { width: 7px; height: 7px; border-radius: 50%; background: var(--line); }
        .savora-wrap .dots-prog i.on { width: 22px; background: var(--caramel); border-radius: 6px; }
        .savora-wrap .ob-foot { margin-top: auto; margin-bottom: 18px; width: 100%; }
        
        .savora-wrap .pair-stage { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; }
        .savora-wrap .radar { width: 200px; height: 200px; border-radius: 50%; display: flex; align-items: center; justify-content: center; position: relative; }
        .savora-wrap .radar .w { position: absolute; inset: 0; border-radius: 50%; border: 1.5px solid rgba(199,123,67,.4); animation: rip 3s ease-out infinite; }
        .savora-wrap .radar .w:nth-child(2) { animation-delay: 1s; }
        .savora-wrap .radar .w:nth-child(3) { animation-delay: 2s; }
        @keyframes rip { 0% { transform: scale(.4); opacity: 0; } 25% { opacity: .9; } 100% { transform: scale(1); opacity: 0; } }
        .savora-wrap .radar .spoon-core { width: 96px; height: 96px; border-radius: 50%; background: radial-gradient(circle at 38% 32%,#F0CB7E,var(--caramel) 75%); display: flex; align-items: center; justify-content: center; box-shadow: 0 0 40px -6px rgba(233,184,92,.55); }
        .savora-wrap .found { width: 100%; background: var(--cream); border: 1px solid var(--line); border-radius: 20px; padding: 15px; display: flex; align-items: center; gap: 13px; margin-top: 8px; }
        .savora-wrap .found .dev { width: 46px; height: 46px; border-radius: 14px; background: var(--oat); display: flex; align-items: center; justify-content: center; flex: none; }
        .savora-wrap .found .nm { font-weight: 600; font-size: 14.5px; color: var(--roast); }
        .savora-wrap .found .mt { font-size: 11.5px; color: var(--roast-soft); margin-top: 2px; display: flex; gap: 10px; }
        .savora-wrap .found .ok { margin-left: auto; color: var(--sage-deep); }
        
        .savora-wrap .filters { display: flex; gap: 8px; margin: 14px 0 4px; overflow: hidden; }
        .savora-wrap .filters .f { padding: 8px 14px; border-radius: 100px; font-size: 12.5px; font-weight: 600; background: var(--cream); border: 1px solid var(--line); color: var(--roast-soft); white-space: nowrap; }
        .savora-wrap .filters .f.on { background: var(--roast); color: #FCF3E6; border-color: var(--roast); }
        .savora-wrap .day-lab { font-size: 11.5px; font-weight: 700; letter-spacing: .06em; text-transform: uppercase; color: var(--roast-soft); margin: 16px 0 9px; }
        .savora-wrap .meal { background: var(--cream); border: 1px solid var(--line); border-radius: 18px; padding: 13px 14px; display: flex; align-items: center; gap: 12px; margin-bottom: 10px; text-align: left; }
        .savora-wrap .meal .ico { width: 42px; height: 42px; border-radius: 13px; display: flex; align-items: center; justify-content: center; flex: none; font-size: 19px; }
        .savora-wrap .meal .nm { font-weight: 600; font-size: 14px; color: var(--roast); }
        .savora-wrap .meal .mt { font-size: 11.5px; color: var(--roast-soft); margin-top: 2px; }
        .savora-wrap .meal .sc { margin-left: auto; text-align: right; }
        .savora-wrap .meal .sc .n { font-family: 'Fraunces', serif; font-size: 20px; font-weight: 500; line-height: 1; color: var(--roast); }
        .savora-wrap .meal .sc .l { font-size: 10px; color: var(--roast-soft); }
        .savora-wrap .tag-na { display: inline-block; font-size: 10.5px; font-weight: 600; padding: 3px 8px; border-radius: 8px; margin-top: 5px; }
        
        .savora-wrap .md-hero { background: linear-gradient(135deg,#fff,#F7EEDF); border: 1px solid var(--line); border-radius: 24px; padding: 18px; margin-top: 14px; text-align: center; }
        .savora-wrap .md-hero .big { font-family: 'Fraunces', serif; font-size: 44px; font-weight: 500; line-height: 1; color: var(--roast); }
        .savora-wrap .md-hero .l { font-size: 12px; color: var(--roast-soft); }
        .savora-wrap .md-row { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 9px; margin-top: 12px; }
        .savora-wrap .md-cell { background: var(--cream); border: 1px solid var(--line); border-radius: 16px; padding: 11px 8px; text-align: center; }
        .savora-wrap .md-cell .v { font-family: 'Fraunces', serif; font-size: 19px; font-weight: 500; color: var(--roast); }
        .savora-wrap .md-cell .v small { font-size: 10px; color: var(--roast-soft); font-family: 'Figtree'; font-weight: 500; }
        .savora-wrap .md-cell .k { font-size: 10px; color: var(--roast-soft); margin-top: 2px; }
        .savora-wrap .panel { background: var(--cream); border: 1px solid var(--line); border-radius: 20px; padding: 15px; margin-top: 12px; text-align: left; }
        .savora-wrap .panel .ph { display: flex; justify-content: space-between; align-items: baseline; }
        .savora-wrap .panel .ph .t { font-size: 13px; font-weight: 600; color: var(--roast); }
        .savora-wrap .panel .ph .s { font-size: 11px; color: var(--roast-soft); }
        
        .savora-wrap .prof { display: flex; align-items: center; gap: 14px; margin-top: 14px; text-align: left; }
        .savora-wrap .prof .av { width: 58px; height: 58px; border-radius: 50%; background: linear-gradient(135deg,var(--honey),var(--caramel)); display: flex; align-items: center; justify-content: center; color: #fff; font-weight: 700; font-size: 22px; flex: none; }
        .savora-wrap .prof .nm { font-family: 'Fraunces', serif; font-size: 20px; font-weight: 500; color: var(--roast); }
        .savora-wrap .prof .mt { font-size: 12px; color: var(--roast-soft); margin-top: 2px; }
        .savora-wrap .goal { background: var(--cream); border: 1px solid var(--line); border-radius: 20px; padding: 15px; margin-top: 12px; text-align: left; }
        .savora-wrap .goal .gh { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
        .savora-wrap .goal .gh .t { font-size: 13.5px; font-weight: 600; color: var(--roast); }
        .savora-wrap .goal .gh .v { font-family: 'Fraunces', serif; font-size: 17px; font-weight: 500; color: var(--caramel); }
        .savora-wrap .track { height: 8px; border-radius: 8px; background: var(--oat); position: relative; }
        .savora-wrap .track i { position: absolute; left: 0; top: 0; bottom: 0; border-radius: 8px; }
        .savora-wrap .track .knob { position: absolute; top: 50%; transform: translate(-50%,-50%); width: 18px; height: 18px; border-radius: 50%; background: #fff; border: 3px solid var(--caramel); box-shadow: 0 2px 6px rgba(53,42,34,.25); }
        .savora-wrap .toggle-row { display: flex; align-items: center; justify-content: space-between; background: var(--cream); border: 1px solid var(--line); border-radius: 18px; padding: 14px 15px; margin-top: 10px; text-align: left; }
        .savora-wrap .toggle-row .tl { font-size: 13.5px; font-weight: 500; color: var(--roast); }
        .savora-wrap .toggle-row .ts { font-size: 11px; color: var(--roast-soft); margin-top: 2px; }
        .savora-wrap .sw { width: 44px; height: 26px; border-radius: 100px; background: var(--sage-deep); position: relative; flex: none; }
        .savora-wrap .sw.off { background: var(--line); }
        .savora-wrap .sw i { position: absolute; top: 3px; width: 20px; height: 20px; border-radius: 50%; background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,.2); transition: .2s; }
        .savora-wrap .sw i { right: 3px; }
        .savora-wrap .sw.off i { right: 21px; }
        
        .savora-wrap .streak-ring { display: flex; flex-direction: column; align-items: center; margin-top: 14px; }
        .savora-wrap .streak-ring .n { font-family: 'Fraunces', serif; font-size: 42px; font-weight: 500; line-height: 1; color: var(--roast); }
        .savora-wrap .streak-ring .l { font-size: 12px; color: var(--roast-soft); }
        .savora-wrap .badges { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 11px; margin-top: 18px; }
        .savora-wrap .badge { background: var(--cream); border: 1px solid var(--line); border-radius: 18px; padding: 14px 8px; text-align: center; }
        .savora-wrap .badge .b { width: 46px; height: 46px; border-radius: 14px; margin: 0 auto 8px; display: flex; align-items: center; justify-content: center; font-size: 22px; }
        .savora-wrap .badge.lock { opacity: .45; }
        .savora-wrap .badge .bn { font-size: 11px; font-weight: 600; line-height: 1.2; color: var(--roast); }
        .savora-wrap .milestone { background: linear-gradient(120deg,#F3EAD9,#FBF4E7); border: 1px solid var(--line); border-radius: 18px; padding: 14px 15px; margin-top: 14px; display: flex; align-items: center; gap: 12px; text-align: left; }
        .savora-wrap .milestone .mn { font-size: 12.5px; line-height: 1.4; color: var(--roast); }
        .savora-wrap .milestone .mn b { font-weight: 700; color: var(--roast); }
        
        .savora-wrap .tabbar { display: flex; justify-content: space-around; align-items: center; padding: 10px 8px 16px; border-top: 1px solid var(--line); background: var(--cream); margin-top: auto; }
        .savora-wrap .tab { display: flex; flex-direction: column; align-items: center; gap: 4px; font-size: 10px; color: var(--roast-soft); font-weight: 500; }
        .savora-wrap .tab.on { color: var(--caramel); }
        .savora-wrap .tab .ti { width: 21px; height: 21px; }
      `}} />

      <div className="savora-wrap">
        <motion.div
          initial={{ opacity: 0, y: 20 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true }}
          className="deck-head"
        >
          <div className="eyebrow">i-Spoon Smart App</div>
          <h2>Inside <em>i-Spoon</em></h2>
          <p>Objective tracking, simple pairing, and everything that makes managing your meals easier.</p>
        </motion.div>

        <div className="phones">
          {/* A. ONBOARDING */}
          <motion.div initial={{ opacity: 0, y: 20 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} className="phone-col">
            <div className="phone"><div className="notch"></div>
              <div className="screen ob">
                <div className="statusbar" style={{ width: "100%" }}><span>9:41</span><div className="dots"><span>📶</span><span className="bat"><i></i></span></div></div>
                <div className="body" style={{ alignItems: "center" }}>
                  <div className="ob-art">
                    <svg width="170" height="150" viewBox="0 0 170 150">
                      <defs>
                        <clipPath id="b2"><ellipse cx="85" cy="66" rx="66" ry="52"/></clipPath>
                        <linearGradient id="br2" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stopColor="#E9B85C"/><stop offset="1" stopColor="#C77B43"/></linearGradient>
                      </defs>
                      <rect x="79" y="96" width="12" height="48" rx="6" fill="#D8B98C"/>
                      <ellipse cx="85" cy="66" rx="66" ry="52" fill="#FDFAF4" stroke="#E6DACA" strokeWidth="2.5"/>
                      <g clipPath="url(#b2)"><path fill="url(#br2)" opacity=".95">
                        <animate attributeName="d" dur="5s" repeatCount="indefinite"
                        values="M-10,52 q22,-8 44,0 t44,0 t44,0 t44,0 V150 H-10Z;M-10,56 q22,8 44,0 t44,0 t44,0 t44,0 V150 H-10Z;M-10,52 q22,-8 44,0 t44,0 t44,0 t44,0 V150 H-10Z"/></path></g>
                      <ellipse cx="85" cy="66" rx="66" ry="52" fill="none" stroke="#E6DACA" strokeWidth="2.5"/>
                    </svg>
                  </div>
                  <div className="ob-tag">your spoon, tracking data</div>
                  <h3>Eat steady,<br/>learn more</h3>
                  <p>i-Spoon tracks tremor, pace and temperature with every bite — so you can monitor your progress over time.</p>
                  <div className="dots-prog"><i className="on"></i><i></i><i></i></div>
                  <div className="ob-foot">
                    <button className="btn-pri">Get started</button>
                    <button className="btn-ghost">I already have a spoon</button>
                  </div>
                </div>
              </div>
            </div>
            <div className="phone-cap"><b>Onboarding</b> · warm welcome, data tracking</div>
          </motion.div>

          {/* B. PAIR SPOON */}
          <motion.div initial={{ opacity: 0, y: 20 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} transition={{ delay: 0.1 }} className="phone-col">
            <div className="phone"><div className="notch"></div>
              <div className="screen">
                <div className="statusbar"><span>9:41</span><div className="dots"><span>📶</span><span className="bat"><i></i></span></div></div>
                <div className="body">
                  <div className="row-head">
                    <div className="back"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#352A22" strokeWidth="2.4"><path d="M15 6l-6 6 6 6" strokeLinecap="round" strokeLinejoin="round"/></svg></div>
                    <div><div className="ttl-lg">Pair your spoon</div><div className="sub-sm">Hold the spoon near your phone</div></div>
                  </div>
                  <div className="pair-stage">
                    <div className="radar">
                      <div className="w"></div><div className="w"></div><div className="w"></div>
                      <div className="spoon-core">
                        <svg width="40" height="40" viewBox="0 0 24 24" fill="#fff" opacity=".95"><ellipse cx="12" cy="6" rx="5" ry="3.6"/><rect x="10.6" y="9" width="2.8" height="13" rx="1.4"/></svg>
                      </div>
                    </div>
                  </div>
                  <div className="found">
                    <div className="dev"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#C77B43" strokeWidth="2"><ellipse cx="12" cy="6" rx="4.5" ry="3"/><path d="M12 9v11"/></svg></div>
                    <div>
                      <div className="nm">i-Spoon · S‑204</div>
                      <div className="mt"><span>🔋 84%</span><span>📶 Strong</span></div>
                    </div>
                    <div className="ok"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#6F8466" strokeWidth="2.4"><path d="M5 12l4 4L19 6" strokeLinecap="round" strokeLinejoin="round"/></svg></div>
                  </div>
                  <div style={{ marginTop: "auto", marginBottom: "16px" }}>
                    <button className="btn-pri">Connect spoon</button>
                    <button className="btn-ghost">Pair manually</button>
                  </div>
                </div>
              </div>
            </div>
            <div className="phone-cap"><b>Pair spoon</b> · BLE discovery + device card</div>
          </motion.div>

          {/* C. HISTORY */}
          <motion.div initial={{ opacity: 0, y: 20 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} transition={{ delay: 0.2 }} className="phone-col">
            <div className="phone"><div className="notch"></div>
              <div className="screen">
                <div className="statusbar"><span>9:41</span><div className="dots"><span>📶</span><span className="bat"><i></i></span></div></div>
                <div className="body">
                  <div className="ttl-lg" style={{ marginTop: "6px" }}>Meal log</div>
                  <div className="filters">
                    <div className="f on">All</div><div className="f">Breakfast</div><div className="f">Lunch</div><div className="f">Dinner</div>
                  </div>
                  <div style={{ overflow: "hidden" }}>
                    <div className="day-lab">Today</div>
                    <div className="meal">
                      <div className="ico" style={{ background: "#FBEFD8" }}>🥣</div>
                      <div><div className="nm">Oats & berries</div><div className="mt">8:10 AM · 11 min</div></div>
                      <div className="sc"><div className="n">82</div><div className="l">score</div></div>
                    </div>
                    <div className="meal">
                      <div className="ico" style={{ background: "#EDF2E3" }}>🥗</div>
                      <div><div className="nm">Quinoa bowl</div><div className="mt">1:05 PM · 16 min</div></div>
                      <div className="sc"><div className="n">76</div><div className="l">score</div></div>
                    </div>
                    <div className="day-lab">Yesterday</div>
                    <div className="meal">
                      <div className="ico" style={{ background: "#FBE5DC" }}>🍲</div>
                      <div>
                        <div className="nm">Miso ramen</div><div className="mt">7:40 PM · 19 min</div>
                        <span className="tag-na" style={{ background: "#FBE0D6", color: "#D86A4B" }}>High tremor phase</span>
                      </div>
                      <div className="sc"><div className="n">64</div><div className="l">score</div></div>
                    </div>
                    <div className="meal">
                      <div className="ico" style={{ background: "#FBEFD8" }}>🥪</div>
                      <div><div className="nm">Avocado toast</div><div className="mt">12:30 PM · 9 min</div></div>
                      <div className="sc"><div className="n">79</div><div className="l">score</div></div>
                    </div>
                  </div>
                </div>
                <div className="tabbar">
                  <div className="tab"><svg className="ti" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M3 11l9-8 9 8M5 10v9h14v-9" strokeLinejoin="round"/></svg>Home</div>
                  <div className="tab on"><svg className="ti" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M8 6h12M8 12h12M8 18h12M3 6h.01M3 12h.01M3 18h.01" strokeLinecap="round"/></svg>Log</div>
                  <div className="tab"><svg className="ti" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M4 19V9M10 19V5M16 19v-7M22 19H2" strokeLinecap="round"/></svg>Insights</div>
                  <div className="tab"><svg className="ti" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="12" cy="8" r="3.5"/><path d="M5 20c0-4 3.5-6 7-6s7 2 7 6"/></svg>You</div>
                </div>
              </div>
            </div>
            <div className="phone-cap"><b>Meal log</b> · grouped by day, tracking score</div>
          </motion.div>

          {/* D. MEAL DETAIL */}
          <motion.div initial={{ opacity: 0, y: 20 }} whileInView={{ opacity: 1, y: 0 }} viewport={{ once: true }} transition={{ delay: 0.3 }} className="phone-col">
            <div className="phone"><div className="notch"></div>
              <div className="screen">
                <div className="statusbar"><span>9:41</span><div className="dots"><span>📶</span><span className="bat"><i></i></span></div></div>
                <div className="body" style={{ overflow: "hidden" }}>
                  <div className="row-head">
                    <div className="back"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#352A22" strokeWidth="2.4"><path d="M15 6l-6 6 6 6" strokeLinecap="round" strokeLinejoin="round"/></svg></div>
                    <div><div className="ttl-lg">Quinoa bowl</div><div className="sub-sm">Lunch · today, 1:05 PM</div></div>
                  </div>
                  <div className="md-hero">
                    <div className="big">76</div>
                    <div className="l">Tremor score · steady, measured</div>
                  </div>
                  <div className="md-row">
                    <div className="md-cell"><div className="v">100<small>Hz</small></div><div className="k">Resolution</div></div>
                    <div className="md-cell"><div className="v">16<small>min</small></div><div className="k">Duration</div></div>
                    <div className="md-cell"><div className="v">31</div><div className="k">Bites</div></div>
                  </div>
                  <div className="panel">
                    <div className="ph"><div className="t">Tremor intensity</div><div className="s">Max amplitude</div></div>
                    <svg width="100%" height="64" viewBox="0 0 240 64" preserveAspectRatio="none" style={{ marginTop: "10px" }}>
                      <defs><linearGradient id="tg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stopColor="#D86A4B" stopOpacity=".3"/><stop offset="1" stopColor="#D86A4B" stopOpacity="0"/></linearGradient></defs>
                      <path d="M0,40 C50,42 90,30 130,28 C180,38 210,42 240,45" fill="none" stroke="#D86A4B" strokeWidth="2.5" strokeLinecap="round"/>
                      <path d="M0,40 C50,42 90,30 130,28 C180,38 210,42 240,45 L240,64 L0,64Z" fill="url(#tg)"/>
                    </svg>
                  </div>
                  <div className="panel">
                    <div className="ph"><div className="t">Pace timeline</div><div className="s">calm throughout</div></div>
                    <div style={{ display: "flex", alignItems: "flex-end", gap: "4px", height: "42px", marginTop: "10px" }}>
                      <i style={{ flex: 1, height: "60%", background: "var(--sage)", borderRadius: "3px" }}></i>
                      <i style={{ flex: 1, height: "75%", background: "var(--sage)", borderRadius: "3px" }}></i>
                      <i style={{ flex: 1, height: "50%", background: "var(--sage)", borderRadius: "3px" }}></i>
                      <i style={{ flex: 1, height: "85%", background: "var(--honey)", borderRadius: "3px" }}></i>
                      <i style={{ flex: 1, height: "45%", background: "var(--sage)", borderRadius: "3px" }}></i>
                      <i style={{ flex: 1, height: "55%", background: "var(--sage)", borderRadius: "3px" }}></i>
                      <i style={{ flex: 1, height: "38%", background: "var(--sage)", borderRadius: "3px" }}></i>
                      <i style={{ flex: 1, height: "48%", background: "var(--sage)", borderRadius: "3px" }}></i>
                    </div>
                  </div>
                </div>
              </div>
            </div>
            <div className="phone-cap"><b>Meal detail</b> · tremor tracking + pace timeline</div>
          </motion.div>

        </div>
      </div>
    </section>
  );
}
