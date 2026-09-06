-- ============================================================================
-- AllWeatherNow Unified Physics-Based Weather, Cloud & Atmosphere Engine (FlyWithLua)
-- ============================================================================

local last_update = 0
local bridge_update_count = 0
local bridge_status = "Waiting for data..."
local engine_enabled = true
local cached_nearest_airport = "Loading..."

local osd_mode = 1
local osd_timer = os.clock()

local noise_seed = math.random(1000, 9999)
math.randomseed(os.time())

-- Sudden Micro-Shear State Variables
local sudden_event_active = false
local sudden_event_timer = 0
local shear_magnitude = 0
local dir_magnitude = 0

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
local d_groundspeed    = XPLMFindDataRef("sim/flightmodel/position/groundspeed") or XPLMFindDataRef("sim/flightmodel/groundspeed")
local d_elevation      = XPLMFindDataRef("sim/flightmodel/position/elevation")
local d_y_agl          = XPLMFindDataRef("sim/flightmodel/position/y_agl")
local d_sat_c          = XPLMFindDataRef("sim/cockpit2/temperature/outside_air_temp_degc")

local region_wind_alt  = safe_dataref_table("sim/weather/region/wind_altitude_msl_m")
local region_wind_dir  = safe_dataref_table("sim/weather/region/wind_direction_degt")
local region_wind_spd  = safe_dataref_table("sim/weather/region/wind_speed_msc")
local region_shear_dir = safe_dataref_table("sim/weather/region/shear_direction_degt")
local region_shear_spd = safe_dataref_table("sim/weather/region/shear_speed_msc")
local region_turb      = safe_dataref_table("sim/weather/region/turbulence")
local xp_inshop_icing  = safe_dataref_table("sim/weather/region/icing_ratio")

local xp_cloud_base    = safe_dataref_table("sim/weather/region/cloud_base_msl_m")
local xp_cloud_tops    = safe_dataref_table("sim/weather/region/cloud_tops_msl_m")
local xp_cloud_cover   = safe_dataref_table("sim/weather/region/cloud_coverage_percent")
local xp_cloud_type    = safe_dataref_table("sim/weather/region/cloud_type")

local xp_temp_c        = safe_dataref_table("sim/weather/region/sealevel_temperature_c")
local xp_dew_c         = safe_dataref_table("sim/weather/region/dewpoint_deg_c")

safe_dataref("xp_qnh_pas", "sim/weather/region/sealevel_pressure_pas", "writable")
safe_dataref("xp_rain_percent", "sim/weather/region/rain_percent", "writable")
safe_dataref("xp_storm_dim", "sim/weather/region/storm_dim", "writable")

safe_dataref("xp_star_gain", "sim/private/controls/stars/gain_photometric", "writable")
safe_dataref("xp_moon_nits", "sim/private/controls/moon/nits", "writable")

safe_dataref("xp_scat_turb", "sim/private/controls/scattering/override_turbidity_t", "writable")
safe_dataref("xp_scat_sing", "sim/private/controls/scattering/single_rat", "writable")
safe_dataref("xp_scat_mult", "sim/private/controls/scattering/multi_rat", "writable")

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
    {base = 600.0,  tops = 1800.0, cover = 0.0, type = 0},
    {base = 3500.0, tops = 5500.0, cover = 0.0, type = 0},
    {base = 8500.0, tops = 10500.0, cover = 0.0, type = 0}
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
    storm_dim = 0.0,
    dust = 0.0,
    pm10 = 0.0
}

local target_w_dir, target_w_spd, target_turb = {}, {}, {}
local target_s_dir, target_s_spd             = {}, {}

local curr_w_dir, curr_w_spd, curr_turb        = {}, {}, {}
local curr_s_dir, curr_s_spd                   = {}, {}

for i = 0, 12 do
    target_w_dir[i], target_w_spd[i], target_turb[i] = 0.0, 0.0, 0.0
    target_s_dir[i], target_s_spd[i]                 = 0.0, 0.0
    curr_w_dir[i], curr_w_spd[i], curr_turb[i]        = 0.0, 0.0, 0.0
    curr_s_dir[i], curr_s_spd[i]                     = 0.0, 0.0
end

function calculate_cloud_icing(ac_alt_msl, sat_temp)
    if sat_temp > 0.0 or sat_temp < -22.0 then return 0.0 end

    local in_cloud = false
    local cloud_weight = 0.0
    for i = 1, 3 do
        local cov = curr_clouds[i].cover > 1.0 and (curr_clouds[i].cover / 100.0) or curr_clouds[i].cover
        if cov > 0.15 and ac_alt_msl >= curr_clouds[i].base and ac_alt_msl <= curr_clouds[i].tops then
            in_cloud = true
            cloud_weight = cov
            break
        end
    end

    if not in_cloud then return 0.0 end

    local temp_factor = math.exp(-math.pow((sat_temp + 10.0) / 6.0, 2))
    local base_icing = target_env.icing_index or 0.5
    
    return math.max(0.0, math.min(1.0, base_icing * cloud_weight * temp_factor))
end

function calculate_cat_shear(layer_idx)
    if layer_idx >= 12 then return 0.0 end

    local dz = fixed_altitudes[layer_idx + 2] - fixed_altitudes[layer_idx + 1]
    if dz <= 0 then return 0.0 end

    local du = (curr_w_spd[layer_idx + 1] or 0.0) - (curr_w_spd[layer_idx] or 0.0)
    local vertical_shear = math.abs(du) / dz

    local layer_spd = curr_w_spd[layer_idx] or 0.0
    if layer_spd < 20.0 then return 0.0 end

    local cat_index = vertical_shear * math.pow(layer_spd / 25.0, 1.5)
    return math.max(0.0, math.min(1.0, cat_index))
end

function calculate_solar_thermals(ac_alt_agl)
    local pbl_height = math.max(1000.0, target_clouds[1].base)
    if ac_alt_agl > pbl_height then return 0.0 end

    local sun_pitch = d_sun_pitch and XPLMGetDataf(d_sun_pitch) or 0.0
    if sun_pitch <= 0.0 then return 0.0 end

    local temp_spread = math.max(0.0, curr_env.temp_c - curr_env.dew_point)
    local solar_factor = math.sin(math.rad(sun_pitch))
    local height_decay = 1.0 - (ac_alt_agl / pbl_height)

    return 0.18 * solar_factor * math.sqrt(temp_spread) * height_decay
end

function calculate_wetbulb_downdraft()
    if curr_env.storm_dim <= 0.0 then return 0.0 end

    local dry_temp = curr_env.temp_c
    local wet_temp = target_env.wet_bulb_c or dry_temp
    local wb_depression = math.max(0.0, dry_temp - wet_temp)

    return 0.35 * wb_depression * math.sqrt(curr_env.storm_dim)
end

local function compute_dynamic_turbulence(base_turb, elapsed_time, ground_speed)
    if base_turb <= 0.0 then return 0.0 end
    
    local speed_factor = math.max(0.5, ground_speed / 150.0)
    local high_freq = math.sin(elapsed_time * 10.5 + noise_seed) * math.cos(elapsed_time * 5.8)
    local low_freq = math.sin(elapsed_time * 0.7 + noise_seed * 0.5)
    
    local noise_envelope = 0.70 + (0.20 * high_freq) + (0.10 * low_freq) * speed_factor
    noise_envelope = math.max(0.2, math.min(1.2, noise_envelope))
    
    return math.max(0.0, math.min(1.0, base_turb * noise_envelope))
end

local function smooth_big_change(current, target, threshold, alpha)
    local diff = math.abs(target - current)
    if diff < 0.001 then return target end

    local dynamic_alpha = alpha
    if diff > threshold * 3.0 then
        dynamic_alpha = math.min(1.0, alpha * 3.0) 
    elseif diff < threshold then
        dynamic_alpha = alpha * 0.5 
    end

    return current + (target - current) * dynamic_alpha
end

local function smooth_big_change_angle(current, target, threshold, alpha)
    local diff = math.abs((target - current + 180) % 360 - 180)
    if diff < 0.01 then return target end

    local dynamic_alpha = alpha
    if diff > threshold * 2.5 then
        dynamic_alpha = math.min(1.0, alpha * 4.0) 
    elseif diff < threshold then
        dynamic_alpha = alpha * 0.5
    end

    local step = (target - current + 180) % 360 - 180
    local res = (current + step * dynamic_alpha) % 360
    if res < 0 then res = res + 360 end
    return res
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
                    
                    if k == "cloud_low"  then target_clouds[1].cover = val end
                    if k == "cloud_mid"  then target_clouds[2].cover = val end
                    if k == "cloud_high" then target_clouds[3].cover = val end

                    if k == "cloud_type_low"  then target_clouds[1].type = val end
                    if k == "cloud_type_mid"  then target_clouds[2].type = val end
                    if k == "cloud_type_high" then target_clouds[3].type = val end

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

function update_nearest_airport_cache()
    local file = io.open(SCRIPT_DIRECTORY .. "nearest_airport.txt", "r")
    if file then
        local content = file:read("*a") or "Unknown"
        file:close()
        content = content:gsub("^%s*Nearest Airport:%s*", "")
        cached_nearest_airport = content:gsub("^%s+", ""):gsub("%s+$", "")
    else
        cached_nearest_airport = "No nearest airport data"
    end
end

function process_seamless_frame()
    if not engine_enabled then return end

    local dt = DELTA_TIME or 0.016
    local alpha = math.min(1.0, dt * 0.22) 
    
    local ac_alt_msl = d_elevation and XPLMGetDataf(d_elevation) or 0.0
    local ac_alt_agl = d_y_agl and XPLMGetDataf(d_y_agl) or 3000.0
    local sat_temp = d_sat_c and XPLMGetDataf(d_sat_c) or curr_env.temp_c
    local ground_speed = d_groundspeed and XPLMGetDataf(d_groundspeed) or 100.0
    
    local elapsed_time = os.clock()

    if d_change_mode then XPLMSetDatai(d_change_mode, 3) end
    if d_update_imm then XPLMSetDatai(d_update_imm, 1) end

    local gust_factor = (ac_alt_agl < 5000.0) and math.max(0.0, 1.0 - (ac_alt_agl / 5000.0)) or 0.0
    local base_gust = (math.sin(elapsed_time * 2.2) + math.sin(elapsed_time * 6.1) * 0.5) * 1.5

    local convective_active = (target_env.cape > 300.0 or curr_env.storm_dim > 0.0)
    if not sudden_event_active and convective_active and math.random() < (0.015 * dt) and ac_alt_agl < 4000.0 then
        sudden_event_active = true
        sudden_event_timer = elapsed_time + (math.random() * 3.0 + 2.0) 
        shear_magnitude = (math.random() * 8.0) - 4.0 
        dir_magnitude = (math.random() * 24.0) - 12.0
    end

    local active_shear = 0.0
    local active_dir_shift = 0.0
    if sudden_event_active then
        if elapsed_time < sudden_event_timer then
            active_shear = shear_magnitude
            active_dir_shift = dir_magnitude
        else
            sudden_event_active = false
        end
    end

    local target_pas = target_env.qnh_inhg * 3386.39

    curr_env.temp_c       = smooth_big_change(curr_env.temp_c, target_env.temp_c, 1.5, alpha)
    curr_env.dew_point    = smooth_big_change(curr_env.dew_point, target_env.dew_point, 1.5, alpha)
    curr_env.qnh_pas      = smooth_big_change(curr_env.qnh_pas, target_pas, 150.0, alpha)
    curr_env.vis_km       = smooth_big_change(curr_env.vis_km, target_env.vis_km, 5.0, alpha)
    curr_env.rain_percent = smooth_big_change(curr_env.rain_percent, target_env.rain_percent, 10.0, alpha)
    curr_env.dust         = smooth_big_change(curr_env.dust, target_env.dust, 20.0, alpha)
    curr_env.pm10         = smooth_big_change(curr_env.pm10, target_env.pm10, 20.0, alpha)
    curr_env.storm_dim    = smooth_big_change(curr_env.storm_dim, target_env.storm_dim, 0.5, alpha)

    if xp_temp_c  then xp_temp_c[0] = curr_env.temp_c end
    if xp_dew_c   then xp_dew_c[0]  = curr_env.dew_point end
    if xp_qnh_pas then xp_qnh_pas   = curr_env.qnh_pas end

    local effective_icing = calculate_cloud_icing(ac_alt_msl, sat_temp)
    if xp_inshop_icing then
        for i = 0, 2 do xp_inshop_icing[i] = effective_icing end
    end

    local max_cloud_top = 0.0
    for i = 1, 3 do
        if target_clouds[i].cover > 10.0 and target_clouds[i].tops > max_cloud_top then
            max_cloud_top = target_clouds[i].tops
        end
    end
    
    local rain_alt_factor = 1.0
    if max_cloud_top > 0.0 and ac_alt_msl > max_cloud_top then
        rain_alt_factor = math.max(0.0, 1.0 - ((ac_alt_msl - max_cloud_top) / 500.0))
    end

    if xp_rain_percent then xp_rain_percent = curr_env.rain_percent * rain_alt_factor end
    if xp_storm_dim then xp_storm_dim = curr_env.storm_dim * rain_alt_factor end

    -- CORRECTED DUST SCATTERING CALCULATION
    local active_dust = math.max(0.0, curr_env.dust - 20.0)
    local active_pm10 = math.max(0.0, curr_env.pm10 - 45.0)
    local combined_particulates = active_dust + (active_pm10 * 0.5)

    local dust_intensity = math.max(0.0, math.min(1.0, combined_particulates / 250.0))

    if dust_intensity > 0.05 then
        if xp_scat_turb then xp_scat_turb = 2.0 + (dust_intensity * 5.0) end
        if xp_scat_sing then xp_scat_sing = 0.75 + (dust_intensity * 1.0) end
        if xp_scat_mult then xp_scat_mult = 0.10 + (dust_intensity * 0.05) end
    else
        if xp_scat_turb then xp_scat_turb = 2.0 end
        if xp_scat_sing then xp_scat_sing = 0.75 end
        if xp_scat_mult then xp_scat_mult = 0.10 end
    end

    if xp_storm_points then
        if curr_env.storm_dim > 0.0 and rain_alt_factor > 0.0 then
            local ac_lat = d_lat and XPLMGetDataf(d_lat) or 26.43
            local ac_lon = d_lon and XPLMGetDataf(d_lon) or 50.10
            for i = 0, 9 do
                local angle = i * 36.0
                local dist_deg = 0.15
                xp_storm_points[i * 3]     = ac_lat + (dist_deg * math.cos(math.rad(angle)))
                xp_storm_points[i * 3 + 1] = ac_lon + (dist_deg * math.sin(math.rad(angle)))
                xp_storm_points[i * 3 + 2] = curr_env.storm_dim * rain_alt_factor
            end
            for k = 30, 89 do xp_storm_points[k] = 0.0 end
        else
            for k = 0, 89 do xp_storm_points[k] = 0.0 end
        end
    end

    if d_vis_sm then
        XPLMSetDataf(d_vis_sm, curr_env.vis_km / 1.60934)
    end

    if curr_env.vis_km < 15.0 then
        local vis_ratio = math.max(0.0, curr_env.vis_km / 15.0)
        local extinction_factor = vis_ratio * vis_ratio

        if xp_star_gain ~= nil then xp_star_gain = 5.0 * extinction_factor end
        if xp_moon_nits ~= nil then xp_moon_nits = 2000.0 * extinction_factor end
    else
        if xp_star_gain ~= nil then xp_star_gain = 5.0 end
        if xp_moon_nits ~= nil then xp_moon_nits = 2000.0 end
    end

    for i = 1, 3 do
        curr_clouds[i].base  = smooth_big_change(curr_clouds[i].base, target_clouds[i].base, 300.0, alpha)
        curr_clouds[i].tops  = smooth_big_change(curr_clouds[i].tops, target_clouds[i].tops, 300.0, alpha)
        curr_clouds[i].cover = smooth_big_change(curr_clouds[i].cover, target_clouds[i].cover, 15.0, alpha)
        curr_clouds[i].type  = target_clouds[i].type

        if xp_cloud_base  then xp_cloud_base[i - 1]  = curr_clouds[i].base end
        if xp_cloud_tops  then xp_cloud_tops[i - 1]  = curr_clouds[i].tops end
        
        local cov_ratio = curr_clouds[i].cover
        if cov_ratio > 1.0 then cov_ratio = cov_ratio / 100.0 end
        cov_ratio = math.max(0.0, math.min(1.0, cov_ratio))

        if xp_cloud_cover then xp_cloud_cover[i - 1] = cov_ratio end
        if xp_cloud_type  then xp_cloud_type[i - 1]  = curr_clouds[i].type end
    end

    if region_wind_alt then
        local cape_shear_add = 0.02 * math.sqrt(2.0 * math.max(0.0, target_env.cape or 0.0)) * (0.5 + 0.5 * math.sin(elapsed_time * 1.1))
        local wb_shear_add = calculate_wetbulb_downdraft() * 0.3

        for i = 0, 12 do
            local cat_turb = calculate_cat_shear(i)
            local thermal_lift = (i == 0 or i == 1) and calculate_solar_thermals(ac_alt_agl) or 0.0

            local target_modulated_turb = compute_dynamic_turbulence(target_turb[i], elapsed_time + (i * 1.3), ground_speed)
            
            local convective_add = math.min(0.35, (cat_turb * 0.45) + (thermal_lift * 0.45))
            target_modulated_turb = math.max(0.0, math.min(1.0, target_modulated_turb + convective_add))

            local layer_shear_target = target_s_spd[i] + math.max(0.0, cape_shear_add) + wb_shear_add

            local spd_target = target_w_spd[i]
            if i == 0 and fixed_altitudes[1] <= 10.0 then
                spd_target = spd_target * math.pow(math.max(2.0, ac_alt_agl) / 10.0, 0.14)
            end

            local layer_noise = 0.0
            local layer_dir_shift = 0.0
            if i <= 3 then
                layer_noise = (base_gust * gust_factor) + (active_shear * (1.0 - (i * 0.2)))
                layer_dir_shift = (sudden_event_active) and (active_dir_shift * (1.0 - (i * 0.2))) or 0.0
                if sudden_event_active then
                    target_modulated_turb = math.min(1.0, target_modulated_turb + math.abs(active_shear * 0.12))
                end
            end

            local final_spd_target = math.max(0.0, spd_target + layer_noise)
            local final_dir_target = (target_w_dir[i] + layer_dir_shift) % 360

            curr_w_dir[i] = smooth_big_change_angle(curr_w_dir[i], final_dir_target, 25.0, alpha)
            curr_w_spd[i] = smooth_big_change(curr_w_spd[i], final_spd_target, 4.0, alpha)
            curr_turb[i]  = smooth_big_change(curr_turb[i], target_modulated_turb, 0.05, alpha)
            curr_s_dir[i] = smooth_big_change_angle(curr_s_dir[i], target_s_dir[i], 25.0, alpha)
            curr_s_spd[i] = smooth_big_change(curr_s_spd[i], layer_shear_target, 3.0, alpha)

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
        update_nearest_airport_cache()
        last_update = os.clock()
    end
end

function draw_weather_osd()
    if osd_mode == 1 and (os.clock() - osd_timer > 10.0) then
        osd_mode = 0
    end

    if osd_mode == 0 then return end

    local sun_pitch = d_sun_pitch and XPLMGetDataf(d_sun_pitch) or 0.0
    local time_state = sun_pitch < 0.0 and "Night" or "Day"

    graphics.set_color(0.0, 0.0, 0.0, 0.75)
    graphics.draw_rectangle(20, 500, 780, 960)

    graphics.set_color(0.2, 0.6, 1.0, 0.8)
    graphics.draw_line(20, 500, 780, 500)
    graphics.draw_line(780, 500, 780, 960)
    graphics.draw_line(780, 960, 20, 960)
    graphics.draw_line(20, 960, 20, 500)

    draw_string(30, 940, "=== AllWeatherNow Weather Engine (" .. time_state .. ") ===", "yellow")
    local status_color = (not engine_enabled) and "red" or (bridge_status:find("Error") and "red" or "green")
    draw_string(30, 920, "Status: " .. bridge_status, status_color)

    local qnh_inhg_val = target_env.qnh_inhg or 29.92
    local qnh_hpa_val = math.floor((qnh_inhg_val * 33.8639) + 0.5)

    local phase_names = {"Clear", "Rain", "Snow", "Wet Snow", "Freezing Rain", "Dust Storm"}
    local p_name = phase_names[(math.floor(target_env.precipitation_phase or 0)) + 1] or "Clear"
    
    draw_string(30, 905, string.format("Temp: %.1fC (Wet: %.1fC) | Dew: %.1fC | QNH: %.2finHg / %dhPa | Vis: %.1fkm | Phase: %s | Storm: %.0f", 
        curr_env.temp_c, target_env.wet_bulb_c or curr_env.temp_c, curr_env.dew_point, qnh_inhg_val, qnh_hpa_val, curr_env.vis_km, p_name, curr_env.storm_dim), "white")
    
    draw_string(30, 890, string.format("CAPE: %.0f J/kg | Ice Index: %.3f | Frz Lvl: %.0fm | Dust: %.1fug/m3 (PM10: %.1f | PM2.5: %.1f) | Dust Ceil: %.0fm", 
        target_env.cape, target_env.icing_index, target_env.freezing_level_m, curr_env.dust, curr_env.pm10, target_env.pm25, target_env.dust_ceiling), "cyan")

    draw_string(30, 875, string.format("Upper Temp (850/700/500hPa): %.1fC / %.1fC / %.1fC | Cover (L/M/H): %.0f%% / %.0f%% / %.0f%% | Types (L/M/H): %d / %d / %d", 
        target_env.temp_850, target_env.temp_700, target_env.temp_500, target_clouds[1].cover, target_clouds[2].cover, target_clouds[3].cover, target_clouds[1].type, target_clouds[2].type, target_clouds[3].type), "cyan")

    draw_string(30, 850, "Lyr | Alt(m) | Dir  | Spd(m/s) | Turb  | Shr Dir | Shr Spd", "yellow")
    for i = 0, 12 do
        local y_pos = 830 - (i * 17)
        local layer_text = string.format(" %-2d | %6.0f | %4.0f°| %5.1f    | %4.3f | %5.1f°  | %4.2f", 
            i, fixed_altitudes[i + 1] or 0, curr_w_dir[i] or 0, curr_w_spd[i] or 0, curr_turb[i] or 0, curr_s_dir[i] or 0, curr_s_spd[i] or 0)
        draw_string(30, y_pos, layer_text, "white")
    end

    draw_string(30, 515, "Nearest Airport: " .. cached_nearest_airport, "yellow")
end

do_often("atmosphere_tick()")
do_every_frame("process_seamless_frame()")
do_every_draw("draw_weather_osd()")