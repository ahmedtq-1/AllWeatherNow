import os
import time
import math
import requests
from datetime import datetime, timezone
import csv

def haversine(lat1, lon1, lat2, lon2):
    R = 6371.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2)**2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return R * c

def calculate_direction(lat1, lon1, lat2, lon2):
    lat1_rad = math.radians(lat1)
    lat2_rad = math.radians(lat2)
    dLon_rad = math.radians(lon2 - lon1)
    
    x = math.sin(dLon_rad) * math.cos(lat2_rad)
    y = math.cos(lat1_rad) * math.sin(lat2_rad) - math.sin(lat1_rad) * math.cos(lat2_rad) * math.cos(dLon_rad)
    
    initial_bearing = math.atan2(x, y)
    compass_bearing = (math.degrees(initial_bearing) + 360) % 360
    return compass_bearing
    
def find_xplane_scripts_dir():
    if os.path.exists("aircraft_loc.txt") or os.path.exists("all_weather_data.txt") or os.path.exists("airports.csv"):
        return os.getcwd()

    drives = ["C", "D", "E", "F", "G", "H"]
    common_subpaths = [
        r"Resources\plugins\FlyWithLua\Scripts",
        r"X-Plane 12\Resources\plugins\FlyWithLua\Scripts",
        r"Steam\steamapps\common\X-Plane 12\Resources\plugins\FlyWithLua\Scripts",
        r"Program Files (x86)\Steam\steamapps\common\X-Plane 12\Resources\plugins\FlyWithLua\Scripts",
        r"Program Files\Laminar Research\X-Plane 12\Resources\plugins\FlyWithLua\Scripts"
    ]

    for drive in drives:
        for subpath in common_subpaths:
            full_path = f"{drive}:\\{subpath}"
            if os.path.isdir(full_path):
                return full_path

    default_path = r"C:\Program Files (x86)\Steam\steamapps\common\X-Plane 12\Resources\plugins\FlyWithLua\Scripts"
    if os.path.isdir(default_path):
        return default_path

    return os.getcwd()

SCRIPT_DIR = find_xplane_scripts_dir()

def fetch_all_weather(lat, lon):
    aq_url = f"https://air-quality-api.open-meteo.com/v1/air-quality?latitude={lat}&longitude={lon}&current=pm10,pm2_5,dust,carbon_monoxide,sulphur_dioxide,aerosol_optical_depth"
    
    wx_url = (
        f"https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lon}"
        "&current=temperature_2m,relative_humidity_2m,dew_point_2m,surface_pressure,pressure_msl,rain,showers,weather_code,"
        "cloud_cover,wind_speed_10m,wind_direction_10m,wind_gusts_10m,boundary_layer_height,cape,freezinglevel_height"
        "&hourly=cloud_cover_low,cloud_cover_mid,cloud_cover_high,surface_pressure,pressure_msl,"
        "temperature_850hPa,temperature_700hPa,temperature_500hPa,"
        "relative_humidity_850hPa,relative_humidity_700hPa,relative_humidity_500hPa,"
        "geopotential_height_1000hPa,geopotential_height_925hPa,geopotential_height_850hPa,"
        "geopotential_height_700hPa,geopotential_height_500hPa,geopotential_height_400hPa,"
        "geopotential_height_300hPa,geopotential_height_250hPa,geopotential_height_200hPa,"
        "geopotential_height_150hPa,geopotential_height_100hPa,"
        "wind_speed_1000hPa,wind_speed_925hPa,wind_speed_850hPa,wind_speed_700hPa,wind_speed_500hPa,"
        "wind_speed_400hPa,wind_speed_300hPa,wind_speed_250hPa,wind_speed_200hPa,wind_speed_150hPa,wind_speed_100hPa,"
        "wind_direction_1000hPa,wind_direction_925hPa,wind_direction_850hPa,wind_direction_700hPa,wind_direction_500hPa,"
        "wind_direction_400hPa,wind_direction_300hPa,wind_direction_250hPa,wind_direction_200hPa,wind_direction_150hPa,wind_direction_100hPa"
        "&wind_speed_unit=ms"
    )

    try:
        # 1. AIR QUALITY FETCH
        dust, pm10, pm25, co, so2, aod = 0.0, 0.0, 10.0, 150.0, 2.0, 0.15
        try:
            aq_req = requests.get(aq_url, timeout=5)
            if aq_req.status_code == 200:
                aq_res = aq_req.json().get('current', {})
                dust = float(aq_res.get('dust') or 0.0)
                pm10 = float(aq_res.get('pm10') or 0.0)
                pm25 = float(aq_res.get('pm2_5') or 10.0)
                co = float(aq_res.get('carbon_monoxide') or 150.0)
                so2 = float(aq_res.get('sulphur_dioxide') or 2.0)
                aod = float(aq_res.get('aerosol_optical_depth') or 0.15)
        except Exception as aq_e:
            print(f"[Warning] Air Quality fetch failed, using clear air defaults: {aq_e}")

        # 2. MAIN WEATHER FETCH
        wx_req = requests.get(wx_url, timeout=5)
        if wx_req.status_code != 200:
            print(f"Surface WX API Error HTTP {wx_req.status_code}")
            return None
        
        wx_data_json = wx_req.json()
        wx_res = wx_data_json.get('current', {})
        hourly_res = wx_data_json.get('hourly', {})

        temp_c = float(wx_res.get('temperature_2m') or 15.0)
        dew_point = float(wx_res.get('dew_point_2m') or 10.0)
        pressure_hpa = float(wx_res.get('pressure_msl') or 1013.25) 
        qnh_inhg = pressure_hpa * 0.0295301

        cape = float(wx_res.get('cape') or 0.0)
        bl_height = float(wx_res.get('boundary_layer_height') or 3000.0)
        dust_ceiling = bl_height + (cape * 0.65)

        raw_cloud_cover = float(wx_res.get('cloud_cover') or 0.0)
        freezing_level = float(wx_res.get('freezinglevel_height') or 0.0)

        rain_mm = float(wx_res.get('rain') or 0.0) + float(wx_res.get('showers') or 0.0)
        wmo_code = int(wx_res.get('weather_code') or 0)
        
        rain_percent = min(1.0, max(0.0, rain_mm / 8.0))
        
        base_dir = float(wx_res.get('wind_direction_10m') or 0.0)
        base_spd = float(wx_res.get('wind_speed_10m') or 2.0)
        gusts_0 = float(wx_res.get('wind_gusts_10m') or (base_spd * 1.3))

        storm_dim = 1.0 if wmo_code in [95, 96, 97, 98, 99] else 0.0
        is_dust_storm = (wmo_code in [30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 98] or dust > 100.0)
        is_snow_storm = (wmo_code in [71, 73, 75, 77, 85, 86] or (temp_c <= 0.0 and rain_mm > 1.0))

        if wmo_code == 97:
            storm_dim = 1.0
            cape = max(cape, 1000.0)
            gusts_0 = max(gusts_0, base_spd * 1.4, 15.0)

        if wmo_code == 98:
            storm_dim = 1.0
            is_dust_storm = True
            dust = max(dust, 180.0)
            pm10 = max(pm10, 240.0)

        if is_dust_storm and dust < 40.0:
            dust = 150.0
            pm10 = 200.0

        # LCL CLOUD BASE CALCULATION
        spread = max(0.2, temp_c - dew_point)
        if spread <= 1.5:
            lcl_base_m = max(120.0, spread * 125.0)
        else:
            lcl_base_m = max(300.0, spread * 125.0)

        lcl_tops_m = lcl_base_m + max(1500.0, rain_mm * 250.0 + 1200.0)

        # SUB-HOURLY CONTINUOUS TIME INTERPOLATION
        hourly_times = hourly_res.get('time', [])
        now_utc = datetime.now(timezone.utc)
        
        h_idx_0 = 0
        h_idx_1 = 0
        t_factor = 0.0

        for idx in range(len(hourly_times) - 1):
            try:
                t0_clean = hourly_times[idx].split(":")[0] + ":00"
                t1_clean = hourly_times[idx+1].split(":")[0] + ":00"
                t0_dt = datetime.strptime(t0_clean, "%Y-%m-%dT%H:%M").replace(tzinfo=timezone.utc)
                t1_dt = datetime.strptime(t1_clean, "%Y-%m-%dT%H:%M").replace(tzinfo=timezone.utc)
                
                if t0_dt <= now_utc <= t1_dt:
                    h_idx_0 = idx
                    h_idx_1 = idx + 1
                    total_sec = (t1_dt - t0_dt).total_seconds()
                    if total_sec > 0:
                        t_factor = (now_utc - t0_dt).total_seconds() / total_sec
                    break
            except Exception:
                pass

        def get_hourly_val(var_name, default=0.0):
            vals = hourly_res.get(var_name, [])
            if h_idx_1 < len(vals) and vals[h_idx_0] is not None and vals[h_idx_1] is not None:
                v0 = float(vals[h_idx_0])
                v1 = float(vals[h_idx_1])
                return v0 + (v1 - v0) * t_factor
            elif h_idx_0 < len(vals) and vals[h_idx_0] is not None:
                return float(vals[h_idx_0])
            return default

        # CLOUD COVERAGE RATIOS (Strict 0.0 - 1.0 for XP12 datarefs)
        raw_low = get_hourly_val('cloud_cover_low', 0.0)
        raw_mid = get_hourly_val('cloud_cover_mid', 0.0)
        raw_high = get_hourly_val('cloud_cover_high', 0.0)

        # Ignore trace coverage under 3% to prevent false cloud triggers
        cloud_low_ratio = 0.0 if raw_low < 3.0 else min(1.0, max(0.0, raw_low / 100.0))
        cloud_mid_ratio = 0.0 if raw_mid < 3.0 else min(1.0, max(0.0, raw_mid / 100.0))
        cloud_high_ratio = 0.0 if raw_high < 3.0 else min(1.0, max(0.0, raw_high / 100.0))
        cloud_cover_ratio = 0.0 if raw_cloud_cover < 3.0 else min(1.0, max(0.0, raw_cloud_cover / 100.0))

        # DYNAMIC CLOUD TYPES (0: None, 1: Cirrus/Stratus, 2: Cumulus, 3: Cumulonimbus)
        if cloud_low_ratio > 0.05:
            if cape > 800 and rain_mm > 0.2:
                cloud_type_low = 3  # Cumulonimbus
            elif cape >= 250 or rain_mm > 0.0:
                cloud_type_low = 2  # Cumulus
            else:
                cloud_type_low = 1  # Stratus
        else:
            cloud_type_low = 0

        cloud_type_mid = 1 if cloud_mid_ratio > 0.05 else 0
        cloud_type_high = 1 if cloud_high_ratio > 0.05 else 0

        # DYNAMIC GEOPOTENTIAL CLOUD HEIGHTS (MSL)
        h_850 = round(get_hourly_val('geopotential_height_850hPa', 1457.0), 1)
        h_700 = round(get_hourly_val('geopotential_height_700hPa', 3012.0), 1)
        h_500 = round(get_hourly_val('geopotential_height_500hPa', 5574.0), 1)
        h_300 = round(get_hourly_val('geopotential_height_300hPa', 9164.0), 1)

        mid_base_m = max(2000.0, h_700 - 500.0)
        mid_tops_m = h_500 if cloud_mid_ratio > 0.6 else mid_base_m + 1800.0
        
        high_base_m = max(6000.0, h_500 + 1000.0)
        high_tops_m = h_300 if cloud_high_ratio > 0.4 else high_base_m + 2200.0

        past_h_idx = max(0, h_idx_0 - 3)
        past_vals = hourly_res.get('pressure_msl', [])
        past_pressure = float(past_vals[past_h_idx]) if past_h_idx < len(past_vals) and past_vals[past_h_idx] is not None else pressure_hpa
        qnh_trend_hpa = pressure_hpa - past_pressure

        t_850 = get_hourly_val('temperature_850hPa', temp_c)
        t_700 = get_hourly_val('temperature_700hPa', temp_c)
        t_500 = get_hourly_val('temperature_500hPa', temp_c)
        rh_850 = get_hourly_val('relative_humidity_850hPa', 50.0)
        rh_700 = get_hourly_val('relative_humidity_700hPa', 50.0)
        rh_500 = get_hourly_val('relative_humidity_500hPa', 40.0)

        icing_index = max(0.0, (rh_850 - 80.0) / 20.0) * math.exp(-((t_850 + 10.0) / 10.0)**2)
        if is_snow_storm:
            icing_index = max(0.9, icing_index)

        rh_2m = float(wx_res.get('relative_humidity_2m') or 70.0)
        try:
            term1 = temp_c * math.atan(0.151977 * math.pow(rh_2m + 8.313659, 0.5))
            term2 = math.atan(temp_c + rh_2m)
            term3 = math.atan(rh_2m - 1.676331)
            term4 = 0.00391838 * math.pow(rh_2m, 1.5) * math.atan(0.023101 * rh_2m)
            wet_bulb_c = term1 + term2 - term3 + term4 - 4.686035
        except Exception:
            wet_bulb_c = temp_c - (0.35 * (temp_c - dew_point))

        is_freezing_rain = (temp_c <= 0.0 and t_850 > 1.0 and rain_mm > 0.1)
        is_wet_snow = (0.0 < wet_bulb_c <= 1.5 and rain_mm > 0.1)

        if is_freezing_rain:
            icing_index = 1.0
            precipitation_phase = 4
        elif is_wet_snow:
            icing_index = max(0.9, icing_index)
            precipitation_phase = 3
        elif is_snow_storm:
            icing_index = max(0.95, icing_index)
            precipitation_phase = 2
        elif is_dust_storm:
            precipitation_phase = 5
        elif rain_mm > 0.1:
            precipitation_phase = 1
        else:
            precipitation_phase = 0

        # VISIBILITY AND ATMOSPHERIC EXTINCTION MODEL
        rh_fraction = min(0.99, max(0.05, rh_2m / 100.0))
        f_rh = pow(1.0 - rh_fraction, -0.3)
        f_rh = max(1.0, min(f_rh, 3.5))
        
        base_extinction = 0.025  
        aod_surface_ext = (aod / 2.5) * (0.6 + (0.4 * rh_fraction))

        pm25_ext = (pm25 * 0.003) * f_rh
        pm10_ext = (pm10 * 0.001) * f_rh
        dust_ext = (dust * 0.0012) * (1.0 + ((f_rh - 1.0) * 0.2))
        smoke_ext = (max(0.0, co - 200.0) * 0.00002) + (max(0.0, so2 - 10.0) * 0.0001)
        
        total_extinction = base_extinction + aod_surface_ext + pm25_ext + pm10_ext + dust_ext + smoke_ext
        calc_vis_km = 3.912 / max(0.005, total_extinction)
        
        if spread <= 1.5:
            calc_vis_km = min(calc_vis_km, 0.2 + (spread * 0.8))

        weather_data = {
            "timestamp_utc": now_utc.strftime("%Y-%m-%d %H:%M:%S"),
            "dust": dust,
            "pm10": pm10,
            "pm25": pm25,
            "dust_ceiling": round(dust_ceiling, 1),
            "qnh_inhg": round(qnh_inhg, 2),
            "qnh_trend_hpa": round(qnh_trend_hpa, 2),
            "temp_c": round(temp_c, 1),
            "dew_point": round(dew_point, 1),
            "wet_bulb_c": round(wet_bulb_c, 1),
            "precipitation_phase": precipitation_phase,
            "vis_km": round(calc_vis_km, 1),
            "rain_percent": round(rain_percent, 3),
            "storm_dim": storm_dim,
            "cloud_cover": round(cloud_cover_ratio, 3),
            "cloud_low": round(cloud_low_ratio, 3),
            "cloud_mid": round(cloud_mid_ratio, 3),
            "cloud_high": round(cloud_high_ratio, 3),
            "cloud_type": cloud_type_low,
            "cloud_type_low": cloud_type_low,
            "cloud_type_mid": cloud_type_mid,
            "cloud_type_high": cloud_type_high,
            "cape": round(cape, 1),
            "icing_index": round(icing_index, 3),
            "freezing_level_m": round(freezing_level, 1),
            "temp_850": round(t_850, 1),
            "temp_700": round(t_700, 1),
            "temp_500": round(t_500, 1),
            "rh_850": round(rh_850, 1),
            "rh_700": round(rh_700, 1),
            "rh_500": round(rh_500, 1),
            "lcl_base_m": round(lcl_base_m, 1),
            "lcl_tops_m": round(lcl_tops_m, 1),
            "mid_base_m": round(mid_base_m, 1),
            "mid_tops_m": round(mid_tops_m, 1),
            "high_base_m": round(high_base_m, 1),
            "high_tops_m": round(high_tops_m, 1),
        }

        pressure_level_mapping = {
            0: ("wind_speed_10m", "wind_direction_10m", None),
            1: ("wind_speed_1000hPa", "wind_direction_1000hPa", "geopotential_height_1000hPa"),
            2: ("wind_speed_925hPa", "wind_direction_925hPa", "geopotential_height_925hPa"),
            3: ("wind_speed_850hPa", "wind_direction_850hPa", "geopotential_height_850hPa"),
            4: ("wind_speed_700hPa", "wind_direction_700hPa", "geopotential_height_700hPa"),
            5: ("wind_speed_500hPa", "wind_direction_500hPa", "geopotential_height_500hPa"),
            6: ("wind_speed_400hPa", "wind_direction_400hPa", "geopotential_height_400hPa"),
            7: ("wind_speed_300hPa", "wind_direction_300hPa", "geopotential_height_300hPa"),
            8: ("wind_speed_250hPa", "wind_direction_250hPa", "geopotential_height_250hPa"),
            9: ("wind_speed_200hPa", "wind_direction_200hPa", "geopotential_height_200hPa"),
            10: ("wind_speed_150hPa", "wind_direction_150hPa", "geopotential_height_150hPa"),
            11: ("wind_speed_100hPa", "wind_direction_100hPa", "geopotential_height_100hPa"),
            12: ("wind_speed_100hPa", "wind_direction_100hPa", "geopotential_height_100hPa"),
        }

        spds = []
        dirs = []

        for i in range(13):
            spd_var, dir_var, height_var = pressure_level_mapping[i]
            if i == 0:
                w_spd = base_spd
                w_dir = int(base_dir)
                w_height = 0.0
            else:
                w_spd = round(get_hourly_val(spd_var, base_spd), 1)
                w_dir = int(get_hourly_val(dir_var, base_dir))
                default_heights = [0, 111, 762, 1457, 3012, 5574, 7185, 9164, 10363, 11784, 13621, 16180, 16180]
                w_height = round(get_hourly_val(height_var, float(default_heights[i])), 1)

            w_dir = w_dir % 360
            spds.append(w_spd)
            dirs.append(w_dir)
            weather_data[f"w_dir_{i}"] = w_dir
            weather_data[f"w_spd_{i}"] = w_spd
            weather_data[f"height_{i}"] = w_height

        for i in range(13):
            if i == 0:
                gust_factor = max(0.0, (gusts_0 - spds[0]))
                shr_spd = round(gust_factor * 0.008, 4)
                shr_dir = float(dirs[0])
                turb = round(min(0.18, max(0.0, (gust_factor / 45.0) ** 1.3)), 4)
            else:
                u_curr = -spds[i] * math.sin(math.radians(dirs[i]))
                v_curr = -spds[i] * math.cos(math.radians(dirs[i]))
                u_prev = -spds[i-1] * math.sin(math.radians(dirs[i-1]))
                v_prev = -spds[i-1] * math.cos(math.radians(dirs[i-1]))

                du = u_curr - u_prev
                dv = v_curr - v_prev

                vector_shr_spd = math.sqrt(du * du + dv * dv)
                dz = max(100.0, weather_data.get(f"height_{i}", 1000) - weather_data.get(f"height_{i-1}", 0))
                normalized_shear = vector_shr_spd / (dz / 100.0)

                if vector_shr_spd > 0.01:
                    shr_dir = (math.degrees(math.atan2(-du, -dv)) + 360) % 360
                else:
                    shr_dir = float(dirs[i])

                shr_spd = round(normalized_shear * 0.05, 4)
                turb = round(min(0.20, max(0.02, normalized_shear * 0.08)), 4)

            # Re-balanced stability bounds
            turb = round(min(0.20, max(0.0, turb)), 4)
            shr_spd = round(max(0.0, min(shr_spd, 0.4)), 4)
            shr_dir = round(shr_dir % 360, 1)

            weather_data[f"turb_{i}"] = turb
            weather_data[f"shr_dir_{i}"] = shr_dir
            weather_data[f"shr_spd_{i}"] = shr_spd

        return weather_data

    except Exception as e:
        print(f"API Fetch Error: {e}")
        return None

def update_airport_data():
    loc_file_path = os.path.join(SCRIPT_DIR, "aircraft_loc.txt")
    if not os.path.exists(loc_file_path):
        return

    parsed_lat = None
    parsed_lon = None
    for _ in range(3):
        try:
            with open(loc_file_path, 'r') as file:
                lines = file.readlines()
                if len(lines) >= 2:
                    parsed_lat = float(lines[0].strip())
                    parsed_lon = float(lines[1].strip())
                    break
        except (ValueError, IOError, PermissionError):
            time.sleep(0.1)

    if parsed_lat is None or parsed_lon is None:
        return

    airports_csv_path = os.path.join(SCRIPT_DIR, "airports.csv")
    if not os.path.exists(airports_csv_path):
        return

    airports = []
    try:
        with open(airports_csv_path, newline='', encoding='utf-8') as csvfile:
            reader = csv.reader(csvfile)
            next(reader, None)
            for row in reader:
                if len(row) < 6:
                    continue
                try:
                    airports.append({
                        "ID": row[1],
                        "Name": row[3],
                        "Latitude": float(row[4]),
                        "Longitude": float(row[5])
                    })
                except ValueError:
                    continue
    except Exception as e:
        print(f"Error reading airports.csv: {e}")
        return

    distance_threshold_km = 250.0
    nearest_airport = None
    nearest_distance = float('inf')
    nearest_direction = 0.0

    for airport in airports:
        distance = haversine(parsed_lat, parsed_lon, airport["Latitude"], airport["Longitude"])
        if distance <= distance_threshold_km and distance < nearest_distance:
            nearest_distance = distance
            nearest_airport = airport
            nearest_direction = calculate_direction(parsed_lat, parsed_lon, airport["Latitude"], airport["Longitude"])

    if nearest_airport:
        print(f"Nearest Airport ID: {nearest_airport['ID']}, Distance: {nearest_distance:.2f} km, Direction: {nearest_direction:.0f}°")
        nearest_airport_file_path = os.path.join(SCRIPT_DIR, "nearest_airport.txt")
        try:
            temp_airport_target = nearest_airport_file_path + ".tmp"
            with open(temp_airport_target, "w") as file:
                file.write(f"Nearest Airport: {nearest_airport['Name']} (ID: {nearest_airport['ID']}, Distance: {nearest_distance:.2f} km, Direction: {nearest_direction:.0f}°)")
            os.replace(temp_airport_target, nearest_airport_file_path)
        except Exception as e:
            print(f"[Warning] Failed to write nearest_airport.txt: {e}")

print("==================================================")
print(" AllWeatherNow - Live Atmospheric Bridge Running")
print(f" Monitoring Path: {SCRIPT_DIR}")
print("==================================================")

last_fetch_time = 0
last_lat = None
last_lon = None
UPDATE_INTERVAL_SEC = 300
DISTANCE_THRESHOLD_KM = 100.0
DEFAULT_LAT = 26.4300
DEFAULT_LON = 50.1000

current_lat = DEFAULT_LAT
current_lon = DEFAULT_LON

# Persistent smoothing caches for ALL 13 pressure levels
smoothed_spds = {}
smoothed_dirs = {}
SMOOTHING_ALPHA = 0.015

while True:
    try:
        try:
            os.makedirs(SCRIPT_DIR, exist_ok=True)
        except Exception:
            pass

        loc_file = os.path.join(SCRIPT_DIR, "aircraft_loc.txt")
        target_data = os.path.join(SCRIPT_DIR, "all_weather_data.txt")

        if os.path.exists(loc_file):
            for _ in range(3):
                try:
                    with open(loc_file, "r") as f:
                        lines = f.readlines()
                        if len(lines) >= 2:
                            current_lat = float(lines[0].strip())
                            current_lon = float(lines[1].strip())
                            break
                except (ValueError, IOError, PermissionError):
                    time.sleep(0.1)

        current_time = time.time()
        needs_update = False

        if last_lat is None or last_lon is None:
            needs_update = True
        else:
            distance_moved = haversine(last_lat, last_lon, current_lat, current_lon)
            time_elapsed = current_time - last_fetch_time
            if time_elapsed >= UPDATE_INTERVAL_SEC or distance_moved >= DISTANCE_THRESHOLD_KM:
                needs_update = True

        if needs_update:
            data = fetch_all_weather(current_lat, current_lon)
            if data:
                print(f"[UPDATE] Pos: {current_lat:.3f}, {current_lon:.3f}")
                print(f" ├─ Low Coverage: {data['cloud_low']:.2f} | Mid: {data['cloud_mid']:.2f} | High: {data['cloud_high']:.2f}")
                print(f" ├─ Low Base: {data['lcl_base_m']} m | Mid Base: {data['mid_base_m']} m | High Base: {data['high_base_m']} m")
                print(f" ├─ Dust: {data['dust']} µg/m³ | PM2.5: {data['pm25']} µg/m³ | Vis: {data['vis_km']} km")
                print(f" └─ QNH: {data['qnh_inhg']} inHg | Temp: {data['temp_c']}°C | DewPoint: {data['dew_point']}°C")
                print("-" * 65)

                last_fetch_time = current_time
                last_lat = current_lat
                last_lon = current_lon

                update_airport_data()

        # Continuous multi-level temporal interpolation (Lerp)
        if 'data' in locals() and data:
            for i in range(13):
                target_spd = data[f"w_spd_{i}"]
                target_dir = data[f"w_dir_{i}"]

                if i not in smoothed_spds:
                    smoothed_spds[i] = target_spd
                    smoothed_dirs[i] = target_dir

                smoothed_spds[i] += (target_spd - smoothed_spds[i]) * SMOOTHING_ALPHA
                
                dir_diff = (target_dir - smoothed_dirs[i] + 540) % 360 - 180
                smoothed_dirs[i] = (smoothed_dirs[i] + dir_diff * SMOOTHING_ALPHA) % 360

                data[f"w_spd_{i}"] = round(smoothed_spds[i], 1)
                data[f"w_dir_{i}"] = round(smoothed_dirs[i], 0)

            try:
                temp_target = target_data + ".tmp"
                with open(temp_target, "w") as out:
                    for key, val in data.items():
                        out.write(f"{key}={val}\n")
                os.replace(temp_target, target_data)
            except Exception as write_err:
                print(f"[Warning] Failed to write weather data file: {write_err}")

    except Exception as outer_e:
        print(f"[LOOP EXCEPTION RECOVERED]: {outer_e}")

    time.sleep(5)