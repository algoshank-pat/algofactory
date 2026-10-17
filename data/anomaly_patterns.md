# Anomaly Signature Library

## Thermal Anomalies

### TH-001: Motor Thermal Overload
**Equipment Type:** Motor  
**Symptoms:** Temperature reading exceeds max_temp_c by 5-15°C; persistent over 10+ minutes.  
**Root Causes:** Bearing friction increase (worn bearings), misalignment, cooling system failure, sustained overload.  
**Detection Method:** Infrared thermal camera; correlate with vibration (if vibration also high, bearings likely failing).  
**Recommended Action:** 
1. Reduce load immediately if possible
2. Inspect bearing for heat, grinding sounds
3. Check cooling system (air intake, fan operation)
4. If persistent after cooling restart, schedule bearing replacement

**Parts to Stage:** Bearing replacement kit (6208 or 6309 per equipment), lubricant (ISO 32 turbine oil), thermal paste.  
**Typical Lead Time:** 2-3 days (bearings); 1 day (lubricant).

### TH-002: Pump Seal Thermal Spike
**Equipment Type:** Pump  
**Symptoms:** Temperature spike 10-20°C above baseline, localized at pump housing seal area.  
**Root Causes:** Seal degradation, friction from contaminated fluid, misalignment.  
**Detection Method:** Dual IR cameras (one on motor, one on pump body); note if motor is cool but pump hot (seal-specific issue).  
**Recommended Action:**
1. Check pump discharge pressure (high pressure + hot seal = friction issue)
2. Monitor for fluid leaks (indicates seal failure imminent)
3. If leak detected, schedule immediate seal replacement
4. If no leak, increase inspection frequency to daily

**Parts to Stage:** Pump seal assembly (SA-42 for standard pumps), hydraulic fluid (ISO 46 per spec).  
**Typical Lead Time:** 3-5 days (seal assembly); 2 days (fluid).

### TH-003: Compressor Piston Ring Thermal Anomaly
**Equipment Type:** Compressor  
**Symptoms:** Sustained high discharge temperature (90-100°C) even after cooldown; motor current draw increases 10-15%.  
**Root Causes:** Worn piston rings (blow-by), valve leakage, inadequate lubrication.  
**Detection Method:** Temperature sensor on discharge line; cross-check with motor current (ammeter).  
**Recommended Action:**
1. Reduce compression ratio if possible (unload compressor)
2. Inspect oil level; top off if low
3. Listen for grinding or metallic sounds (piston ring damage)
4. If motor current remains elevated after oil top-off, schedule ring replacement

**Parts to Stage:** Piston ring kit (PR-88), compressor oil (mineral, ISO 46).  
**Typical Lead Time:** 5-7 days (ring kit, requires internal inspection); 1 day (oil).

---

## Vibration Anomalies

### VB-001: Motor Bearing Wear Signature
**Equipment Type:** Motor  
**Symptoms:** Vibration amplitude 1.5-2x baseline (baseline typically 1-2 mm/s); localized at bearing housings.  
**Root Causes:** Bearing wear, misalignment, unbalance.  
**Detection Method:** Accelerometer on bearing housing; spectrum analysis (look for 1x, 2x, 3x running speed peaks and bearing defect frequencies).  
**Recommended Action:**
1. Measure runout at bearing housing (if >0.5mm, likely misalignment or wear)
2. If vibration worsens over hours, schedule immediate bearing replacement
3. If stable, increase monitoring to every 4 hours until replacement scheduled

**Parts to Stage:** Replacement bearing (match equipment_id in database), alignment shims, bearing puller tool.  
**Typical Lead Time:** 2-3 days (bearing); tools on-site.

### VB-002: Pump Cavitation Signature
**Equipment Type:** Pump  
**Symptoms:** Broadband high-frequency noise (>10 kHz) and vibration; erratic displacement.  
**Root Causes:** Inlet pressure too low, suction line blockage, fluid viscosity too high.  
**Detection Method:** Accelerometer on pump inlet; spectrum shows high-frequency rumble; audible grinding.  
**Recommended Action:**
1. Check inlet strainer (likely blocked); replace strainer element
2. Verify inlet pressure gauge (should be >0.3 bar gauge; below 0 = cavitation imminent)
3. If strainer clear and pressure low, check suction line for kinks/blockages
4. If cavitation persists, reduce flow demand (throttle outlet pressure)

**Parts to Stage:** Pump inlet strainer element, hose clamps, suction line check valve (if worn).  
**Typical Lead Time:** 1 day (strainer element, on-site); 2 days (check valve if replacement needed).

### VB-003: Fan Blade Imbalance
**Equipment Type:** Fan  
**Symptoms:** Vibration 2-3x baseline, fundamental frequency = running speed (1x), directional (may only appear on specific axis).  
**Root Causes:** Blade fouling (dust/dirt accumulation), blade crack, bearing wear.  
**Detection Method:** Accelerometer on fan bearing housing, measure on multiple planes (radial, axial).  
**Recommended Action:**
1. Visually inspect fan blades for dirt, cracks, deformation
2. Clean blades and shroud if fouled (especially in humid plants)
3. If vibration still high after cleaning, suspect bearing wear (see VB-001)
4. If blade visibly cracked, schedule immediate replacement

**Parts to Stage:** Replacement fan blade set, bearing replacement kit, cleaning supplies.  
**Typical Lead Time:** 2-3 days (blades); 2-3 days (bearings).

---

## Acoustic Anomalies

### AC-001: Air Leak (High-Frequency Whistle)
**Equipment Type:** Compressor, Pump (pressurized systems)  
**Symptoms:** High-frequency hissing/whistling sound; ultrasonic microphone detects 20-40 kHz spikes; audible in quiet environment.  
**Root Causes:** Gasket failure, threaded connection loosened, seal degradation, pressure relief valve stuck open.  
**Detection Method:** Ultrasonic microphone array (pinpoint leak location by triangulation); acoustic frequency analysis.  
**Recommended Action:**
1. Locate leak using ultrasonic probe (triangulate if possible)
2. If leak at connection, tighten gently (do not over-torque)
3. If leak at gasket, depressurize and replace gasket
4. If leak at relief valve, clean or replace valve cartridge
5. Monitor pressure downstream (if dropping, leak confirmed and significant)

**Parts to Stage:** Gasket kit (fluid-specific: air, hydraulic, refrigerant), thread sealant (PTFE tape), relief valve cartridge.  
**Typical Lead Time:** 1-2 days (gaskets, cartridges, tape on-site).

### AC-002: Motor Grinding Noise (Bearing Damage)
**Equipment Type:** Motor  
**Symptoms:** Grinding, scraping, or irregular metallic rattle; worsens under load; distinct from normal hum.  
**Root Causes:** Bearing race failure, loose rotor bar, internal short circuit.  
**Detection Method:** Acoustic monitoring (low-frequency rumble typically indicates bearing failure); correlate with temperature (if temp normal but grinding present, may be electrical short).  
**Recommended Action:**
1. Shut down immediately (bearing failure is imminent)
2. Inspect bearing housing for heat, smells (burned insulation = electrical issue)
3. Do not restart under load until inspected
4. Schedule bearing replacement or motor rewind (if electrical)

**Parts to Stage:** Replacement bearing, motor rewind service (if needed), lubricant.  
**Typical Lead Time:** 2-3 days (bearing); 5-7 days (motor rewind service).

---

## Procedural Cross-References

- **Temperature Validation:** Always cross-check IR thermal reading with contact thermocouple (2-3°C tolerance) to rule out sensor fouling.
- **Vibration Baseline:** Establish baseline immediately after equipment commissioning or bearing replacement. Use this as reference; baseline can drift ±10% over 6 months.
- **Hybrid Detection:** Thermal + Vibration anomalies often appear together (e.g., bearing wear shows as both vibration + heat). Retrieve both anomaly signatures when one is triggered.
- **Seasonal Effects:** Summer increases baseline temperatures by 3-5°C; winter baseline ~2°C lower. Adjust thresholds seasonally.
- **Wet-Wash Operations:** On humid days or post-wash, thermal baselines can temporarily drop 5-10°C. Monitor for thermal spikes for 2 hours post-wash to distinguish transient cooling from actual anomalies.

