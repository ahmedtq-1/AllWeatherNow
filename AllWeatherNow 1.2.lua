-- ============================================================================
-- AllWeatherNow Unified Physics-Based Weather, Cloud & Atmosphere Engine (FlyWithLua)
-- Integrated with Python Live Atmospheric Bridge (Conditional Big-Change Smoothing)
-- ============================================================================

local last_update = 0
local bridge_update_count = 0
local bridge_status = "Waiting for data..."
local engine_enabled = true

local osd_mode = 1
local osd_timer = os.clock()

-- OSD & Engine Control Callbacks
function trigger_timed_osd()
    osd_mode = 1
    osd_timer = os.clock()
end

function toggle_persistent_osd()
    osd_mode = (osd_mode == 2) and 0 or 2
end

function enable_weather_engine()
    engine_enabled = true
    bridge_status = "Engine Enabled"
end

function disable_weather_engine()
    engine_enabled = false
    bridge_status = "Engine Disabled"
end

function toggle_weather_engine()
    if engine_enabled then
        disable_weather_engine()
    else
        enable_weather_engine()
    end
end

add_macro("AllWeatherNow: Show OSD (10s)", "trigger_timed_osd()")
add_macro("AllWeatherNow: Toggle Persistent OSD", "toggle_persistent_osd()")
add_macro("AllWeatherNow: Enable Weather Engine", "enable_weather_engine()")
add_macro("AllWeatherNow: Disable Weather Engine", "disable_weather_engine()")
add_macro("AllWeatherNow: Toggle Weather Engine On/Off", "toggle_weather_engine()")

-- Safe DataRef Binding Helpers (Prevents Null Pointer Crashes)
local function safe_dataref_table(name)
    if XPLMFindDataRef(name) ~= nil then
        return dataref_table(name)
    end
    return nil
end

local function safe_dataref(var_name, name, access)
    if XPLMFindDataRef(name) ~= nil then
        dataref(var_name, name, access)
        return true
    end
    return false
end

-- X-Plane Dataref Hooks
local d_sun_pitch      = XPLMFindDataRef("sim/graphics/scenery/sun_pitch_degrees")
local d_vis_sm         = XPLMFindDataRef("sim/weather/region/visibility_reported_sm")
local d_change_mode    = XPLMFindDataRef("sim/weather/region/change_mode")
local d_update_imm     = XPLMFindDataRef("sim/weather/region/update_immediately")
local d_lat            = XPLMFindDataRef("sim/flightmodel/position/latitude")
local d_lon            = XPLMFindDataRef("sim/flightmodel/position/longitude")

local region_wind_alt  = safe_dataref_table("sim/weather/region/wind_altitude_msl_m")
local region_wind_dir  = safe_dataref_table("sim/weather/region/wind_direction_degt")
local region_wind_spd  = safe_dataref_table("sim/weather/region/wind_speed_msc")
local region_shear_dir = safe_dataref_table("sim/weather/region/shear_direction_degt")
local region_shear_spd = safe_dataref_table("sim/weather/region/shear_speed_msc")
local region_turb      = safe_dataref_table("sim/weather/region/turbulence")

local xp_cloud_base    = safe_dataref_table("sim/weather/region/cloud_base_msl_m")
local xp_cloud_tops    = safe_dataref_table("sim/weather/region/cloud_tops_msl_m")
local xp_cloud_cover   = safe_dataref_table("sim/weather/region/cloud_coverage_percent")
local xp_cloud_type    = safe_dataref_table("sim/weather/region/cloud_type")

local xp_temp_c        = safe_dataref_table("sim/weather/region/sealevel_temperature_c")
local xp_dew_c         = safe_dataref_table("sim/weather/region/dewpoint_deg_c")

safe_dataref("xp_qnh_pas", "sim/weather/region/sealevel_pressure_pas", "writable")
safe_dataref("xp_rain_percent", "sim/weather/region/rain_percent", "writable")
safe_dataref("xp_storm_dim", "sim/weather/region/storm_dim", "writable")

-- Low-Visibility Photometric Datarefs for Stars & Moon Dimming
safe_dataref("xp_star_gain", "sim/private/controls/stars/gain_photometric", "writable")
safe_dataref("xp_moon_nits", "sim/private/controls/moon/nits", "writable")

local xp_storm_points  = safe_dataref_table("sim/weather/region/storm_points")

local fixed_altitudes = {
    0.0, 540.1056, 988.46643, 1948.2816, 3010.8145, 
    4206.545, 5572.049, 7182.307, 9160.154, 
    10362.8955, 11887.2, 13594.08, 16179.394
}

local target_env = {
    temp_c = 15.0,
    dew_point = 10.0,
    wet_bulb_c = 12.0,
    precipitation_phase = 0,
    qnh_inhg = 29.92,
    qnh_trend_hpa = 0.0,
    vis_km = 32.0,
    dust = 0.0,
    pm10 = 0.0,
    pm25 = 0.0,
    dust_ceiling = 3000.0,
    rain_percent = 0.0,
    storm_dim = 0.0,
    cape = 0.0,
    icing_index = 0.0,
    freezing_level_m = 0.0,
    temp_850 = 15.0,
    temp_700 = 10.0,
    temp_500 = -10.0
}

local target_clouds = {
    {base = 600.0,  tops = 1800.0, cover = 0.0, type = 0}, -- Low Layer
    {base = 3500.0, tops = 5500.0, cover = 0.0, type = 0}, -- Mid Layer
    {base = 8500.0, tops = 10500.0, cover = 0.0, type = 0}  -- High Layer
}

local curr_clouds = {
    {base = 600.0,  tops = 1800.0, cover = 0.0, type = 0},
    {base = 3500.0, tops = 5500.0, cover = 0.0, type = 0},
    {base = 8500.0, tops = 10500.0, cover = 0.0, type = 0}
}

local curr_env = {
    temp_c = 15.0,
    dew_point = 10.0,
    qnh_pas = 101325.0,
    vis_km = 32.0,
    rain_percent = 0.0,
    storm_dim = 0.0
}

local target_w_dir, target_w_spd, target_turb = {}, {}, {}
local target_s_dir, target_s_spd              = {}, {}

local curr_w_dir, curr_w_spd, curr_turb        = {}, {}, {}
local curr_s_dir, curr_s_spd                  = {}, {}

for i = 0, 12 do
    target_w_dir[i], target_w_spd[i], target_turb[i] = 0.0, 0.0, 0.0
    target_s_dir[i], target_s_spd[i]              = 0.0, 0.0
    curr_w_dir[i], curr_w_spd[i], curr_turb[i]        = 0.0, 0.0, 0.0
    curr_s_dir[i], curr_s_spd[i]                  = 0.0, 0.0
end

-- Conditional Big-Change Smoothing Helpers
local function smooth_big_change(current, target, threshold, alpha)
    local diff = math.abs(target - current)
    if diff > threshold then
        -- Big change detected: apply smooth gradual transition
        return current + (target - current) * alpha
    else
        -- Small change: snap instantly to avoid micro-lag
        return target
    end
end

local function smooth_big_change_angle(current, target, threshold, alpha)
    local diff = math.abs((target - current + 180) % 360 - 180)
    if diff > threshold then
        local step = (target - current + 180) % 360 - 180
        local res = current + step * alpha
        if res < 0 then res = res + 360 end
        if res >= 360 then res = res - 360 end
        return res
    else
        return target
    end
end

function export_aircraft_location()
    local lat = d_lat and XPLMGetDataf(d_lat) or 0.0
    local lon = d_lon and XPLMGetDataf(d_lon) or 0.0

    local file = io.open(SCRIPT_DIRECTORY .. "aircraft_loc.txt", "w")
    if file then
        file:write(string.format("%.6f\n%.6f\n", lat, lon))
        file:close()
    end
end

function update_weather_bridge()
    local file = io.open(SCRIPT_DIRECTORY .. "all_weather_data.txt", "r")
    if file then
        for line in file:lines() do
            local k, v = line:match("([^=]+)=([^=]+)")
            if k and v then
                local val = tonumber(v)
                if val then
                    if target_env[k] ~= nil then target_env[k] = val end
                    
                    -- Cloud Cover
                    if k == "cloud_low"  then target_clouds[1].cover = val end
                    if k == "cloud_mid"  then target_clouds[2].cover = val end
                    if k == "cloud_high" then target_clouds[3].cover = val end

                    -- Decoupled Cloud Types
                    if k == "cloud_type_low"  then target_clouds[1].type = val end
                    if k == "cloud_type_mid"  then target_clouds[2].type = val end
                    if k == "cloud_type_high" then target_clouds[3].type = val end

                    -- Decoupled Multi-Layer Altitude Boundaries
                    if k == "lcl_base_m"  then target_clouds[1].base = val end
                    if k == "lcl_tops_m"  then target_clouds[1].tops = val end
                    if k == "mid_base_m"  then target_clouds[2].base = val end
                    if k == "mid_tops_m"  then target_clouds[2].tops = val end
                    if k == "high_base_m" then target_clouds[3].base = val end
                    if k == "high_tops_m" then target_clouds[3].tops = val end

                    for i = 0, 12 do
                        if k == "w_dir_" .. i    then target_w_dir[i] = val end
                        if k == "w_spd_" .. i    then target_w_spd[i] = val end
                        if k == "turb_" .. i     then target_turb[i]  = val end
                        if k == "shr_dir_" .. i then target_s_dir[i] = val end
                        if k == "shr_spd_" .. i then target_s_spd[i] = val end
                    end
                end
            end
        end
        file:close()
        bridge_update_count = bridge_update_count + 1
        bridge_status = "Connected (Updates: " .. bridge_update_count .. ")"
    else
        bridge_status = "Error: all_weather_data.txt missing"
    end
end

function read_nearest_airport()
    local file = io.open(SCRIPT_DIRECTORY .. "nearest_airport.txt", "r")
    if file then
        local nearest_airport = file:read("*a")
        file:close()
        return nearest_airport
    else
        return "No nearest airport data"
    end
end

function process_seamless_frame()
    if not engine_enabled then return end

    local dt = DELTA_TIME or 0.016
    local alpha = math.min(1.0, dt * 0.4) -- Gentle smoothing rate for major shifts

    if d_change_mode then XPLMSetDatai(d_change_mode, 3) end
    if d_update_imm then XPLMSetDatai(d_update_imm, 1) end

    local target_pas = target_env.qnh_inhg * 3386.39

    -- Apply conditional smoothing: only smooth if changes breach significant thresholds
    curr_env.temp_c     = smooth_big_change(curr_env.temp_c, target_env.temp_c, 1.5, alpha)          -- Threshold: 1.5 °C
    curr_env.dew_point    = smooth_big_change(curr_env.dew_point, target_env.dew_point, 1.5, alpha)    -- Threshold: 1.5 °C
    curr_env.qnh_pas      = smooth_big_change(curr_env.qnh_pas, target_pas, 150.0, alpha)              -- Threshold: ~1.5 hPa
    curr_env.vis_km       = smooth_big_change(curr_env.vis_km, target_env.vis_km, 5.0, alpha)          -- Threshold: 5.0 km
    curr_env.rain_percent = smooth_big_change(curr_env.rain_percent, target_env.rain_percent, 10.0, alpha) -- Threshold: 10%

    if xp_temp_c  then xp_temp_c[0] = curr_env.temp_c end
    if xp_dew_c   then xp_dew_c[0]  = curr_env.dew_point end
    if xp_qnh_pas then xp_qnh_pas   = curr_env.qnh_pas end

    if xp_rain_percent then xp_rain_percent = curr_env.rain_percent end
    if xp_storm_dim then xp_storm_dim = target_env.storm_dim end

    -- Dynamic Storm Ring Generation centered on Aircraft
    if xp_storm_points then
        if target_env.storm_dim > 0.0 then
            local ac_lat = d_lat and XPLMGetDataf(d_lat) or 26.43
            local ac_lon = d_lon and XPLMGetDataf(d_lon) or 50.10
            for i = 0, 9 do
                local angle = i * 36.0
                local dist_deg = 0.15
                xp_storm_points[i * 3 + 1] = ac_lat + (dist_deg * math.cos(math.rad(angle)))
                xp_storm_points[i * 3 + 2] = ac_lon + (dist_deg * math.sin(math.rad(angle)))
                xp_storm_points[i * 3 + 3] = target_env.storm_dim
            end
            for k = 30, 99 do xp_storm_points[k] = 0.0 end
        else
            for k = 0, 99 do xp_storm_points[k] = 0.0 end
        end
    end

    -- Extinction-Calculated Visibility Injection
    if d_vis_sm then
        XPLMSetDataf(d_vis_sm, curr_env.vis_km / 1.60934)
    end

    -- Photometric Extinction & Dimming for Stars & Moon Under Low Visibility (< 15km)
    if curr_env.vis_km < 15.0 then
        local vis_ratio = math.max(0.0, curr_env.vis_km / 15.0)
        local extinction_factor = vis_ratio * vis_ratio

        if xp_star_gain ~= nil then
            xp_star_gain = 5.0 * extinction_factor
        end
        if xp_moon_nits ~= nil then
            xp_moon_nits = 2000.0 * extinction_factor
        end
    end

    -- Inject Decoupled Cloud Layers with Big-Change Conditional Smoothing
    for i = 1, 3 do
        curr_clouds[i].base  = smooth_big_change(curr_clouds[i].base, target_clouds[i].base, 300.0, alpha)   -- Threshold: 300m
        curr_clouds[i].tops  = smooth_big_change(curr_clouds[i].tops, target_clouds[i].tops, 300.0, alpha)   -- Threshold: 300m
        curr_clouds[i].cover = smooth_big_change(curr_clouds[i].cover, target_clouds[i].cover, 15.0, alpha) -- Threshold: 15%
        curr_clouds[i].type  = target_clouds[i].type

        if xp_cloud_base  then xp_cloud_base[i - 1]  = curr_clouds[i].base end
        if xp_cloud_tops  then xp_cloud_tops[i - 1]  = curr_clouds[i].tops end
        
        local cov_ratio = curr_clouds[i].cover
        if cov_ratio > 1.0 then
            cov_ratio = cov_ratio / 100.0
        end
        cov_ratio = math.max(0.0, math.min(1.0, cov_ratio))

        if xp_cloud_cover then xp_cloud_cover[i - 1] = cov_ratio end
        if xp_cloud_type  then xp_cloud_type[i - 1]  = curr_clouds[i].type end
    end

    if xp_cloud_cover then
        for k = 3, 5 do
            xp_cloud_cover[k] = 0.0
        end
    end

    if region_wind_alt then
        for i = 0, 12 do
            -- Conditional smoothing thresholds for wind layers: >25° dir, >4 m/s spd, >0.05 turb
            curr_w_dir[i] = smooth_big_change_angle(curr_w_dir[i], target_w_dir[i], 25.0, alpha)
            curr_w_spd[i] = smooth_big_change(curr_w_spd[i], target_w_spd[i], 4.0, alpha)
            curr_turb[i]  = smooth_big_change(curr_turb[i], target_turb[i], 0.05, alpha)
            curr_s_dir[i] = smooth_big_change_angle(curr_s_dir[i], target_s_dir[i], 25.0, alpha)
            curr_s_spd[i] = smooth_big_change(curr_s_spd[i], target_s_spd[i], 3.0, alpha)

            region_wind_alt[i]  = fixed_altitudes[i + 1] or 0.0
            region_wind_dir[i]  = curr_w_dir[i]
            region_wind_spd[i]  = curr_w_spd[i]
            region_turb[i]      = curr_turb[i]
            region_shear_dir[i] = curr_s_dir[i]
            region_shear_spd[i] = curr_s_spd[i]
        end
    end
end

function atmosphere_tick()
    if not engine_enabled then return end

    if os.clock() > last_update + 3 then
        export_aircraft_location()
        update_weather_bridge()
        last_update = os.clock()
    end
end

function draw_weather_osd()
    if osd_mode == 1 then
        if os.clock() - osd_timer > 10.0 then
            osd_mode = 0
        end
    end

    if osd_mode == 0 then return end

    local sun_pitch = d_sun_pitch and XPLMGetDataf(d_sun_pitch) or 0.0
    local time_state = sun_pitch < 0.0 and "Night" or "Day"

    draw_string(30, 940, "=== AllWeatherNow Weather Engine (" .. time_state .. ") ===", "yellow")
    local status_color = (not engine_enabled) and "red" or (bridge_status:find("Error") and "red" or "green")
    draw_string(30, 920, "Status: " .. bridge_status, status_color)

    -- Line 1: Surface Dynamics & Barometric Pressure
    local phase_names = {"Clear", "Rain", "Snow", "Wet Snow", "Freezing Rain", "Dust Storm"}
    local p_name = phase_names[(math.floor(target_env.precipitation_phase or 0)) + 1] or "Clear"
    draw_string(30, 905, string.format("Temp: %.1fC (Wet: %.1fC) | Dew: %.1fC | QNH: %.2finHg | Vis: %.1fkm | Phase: %s | Storm: %.0f", 
        curr_env.temp_c, target_env.wet_bulb_c or curr_env.temp_c, curr_env.dew_point, target_env.qnh_inhg, curr_env.vis_km, p_name, target_env.storm_dim), "white")
    
    -- Line 2: Atmospheric Convection, Aerosols & Microphysics
    draw_string(30, 890, string.format("CAPE: %.0f J/kg | Ice Index: %.3f | Frz Lvl: %.0fm | Dust: %.1fug/m3 (PM10: %.1f | PM2.5: %.1f) | Dust Ceil: %.0fm", 
        target_env.cape, target_env.icing_index, target_env.freezing_level_m, target_env.dust, target_env.pm10, target_env.pm25, target_env.dust_ceiling), "light_cyan")

    -- Line 3: Upper Air Thermal Profile & Decoupled Cloud Diagnostics
    draw_string(30, 875, string.format("Upper Temp (850/700/500hPa): %.1fC / %.1fC / %.1fC | Cover (L/M/H): %.0f%% / %.0f%% / %.0f%% | Types (L/M/H): %d / %d / %d", 
        target_env.temp_850, target_env.temp_700, target_env.temp_500, target_clouds[1].cover, target_clouds[2].cover, target_clouds[3].cover, target_clouds[1].type, target_clouds[2].type, target_clouds[3].type), "cyan")

    -- Line 4+: 13-Layer Wind Matrix
    draw_string(30, 850, "Lyr | Alt(m) | Dir  | Spd(m/s) | Turb  | Shr Dir | Shr Spd", "yellow")
    for i = 0, 12 do
        local y_pos = 830 - (i * 17)
        local layer_text = string.format(" %-2d | %6.0f | %4.0f°| %5.1f    | %4.3f | %5.1f°  | %4.2f", 
            i, fixed_altitudes[i + 1] or 0, curr_w_dir[i] or 0, curr_w_spd[i] or 0, curr_turb[i] or 0, curr_s_dir[i] or 0, curr_s_spd[i] or 0)
        draw_string(30, y_pos, layer_text, "white")
    end

    -- Nearest Airport Information
    local nearest_airport = read_nearest_airport()
    draw_string(30, 595, "Nearest Airport: " .. nearest_airport, "yellow")
end

-- FlyWithLua Loop Registrations
do_often("atmosphere_tick()")
do_every_frame("process_seamless_frame()")
do_every_draw("draw_weather_osd()")