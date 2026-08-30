import os
import time
import math
import requests
from datetime import datetime, timezone

SCRIPT_DIR = r"C:\Program Files (x86)\Steam\steamapps\common\X-Plane 12\Resources\plugins\FlyWithLua\Scripts"

def haversine(lat1, lon1, lat2, lon2):
    R = 6371.0
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat / 2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon / 2)**2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return R * c

def fetch_all_weather(lat, lon):
    aq_url = f"https://air-quality-api.open-meteo.com/v1/air-quality?latitude={lat}&longitude={lon}&current=pm10,pm2_5,dust"
    
    wx_url = (
        f"https://api.open-meteo.com/v1/forecast?latitude={lat}&longitude={lon}"
        "&current=temperature_2m,relative_humidity_2m,dew_point_2m,surface_pressure,rain,showers,weather_code,"
        "cloud_cover,wind_speed_10m,wind_direction_10m,wind_gusts_10m,boundary_layer_height,cape,freezinglevel_height"
        "&hourly=cloud_cover_low,cloud_cover_mid,cloud_cover_high,surface_pressure,"
        "temperature_850hPa,temperature_700hPa,temperature_500hPa,"
        "relative_humidity_850hPa,relative_humidity_700hPa,relative_humidity_500hPa,"
        "wind_speed_1000hPa,wind_speed_925hPa,wind_speed_850hPa,wind_speed_700hPa,wind_speed_500hPa,"
        "wind_speed_400hPa,wind_speed_300hPa,wind_speed_250hPa,wind_speed_200hPa,wind_speed_150hPa,wind_speed_100hPa,"
        "wind_direction_1000hPa,wind_direction_925hPa,wind_direction_850hPa,wind_direction_700hPa,wind_direction_500hPa,"
        "wind_direction_400hPa,wind_direction_300hPa,wind_direction_250hPa,wind_direction_200hPa,wind_direction_150hPa,wind_direction_100hPa"
        "&wind_speed_unit=ms"
    )

    try:
        # 1. ISOLATED AIR QUALITY FETCH (Prevents WX crash if AQ API goes offline)
        dust, pm10, pm25 = 0.0, 0.0, 10.0
        try:
            aq_req = requests.get(aq_url, timeout=5)
            if aq_req.status_code == 200:
                aq_res = aq_req.json().get('current', {})
                dust = float(aq_res.get('dust') or 0.0)
                pm10 = float(aq_res.get('pm10') or 0.0)
                pm25 = float(aq_res.get('pm2_5') or 10.0)
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
        pressure_hpa = float(wx_res.get('surface_pressure') or 1013.25)
        qnh_inhg = pressure_hpa * 0.0295301

        cape = float(wx_res.get('cape') or 0.0)
        bl_height = float(wx_res.get('boundary_layer_height') or 3000.0)
        dust_ceiling = bl_height + (cape * 0.65)

        cloud_cover = float(wx_res.get('cloud_cover') or 0.0)
        freezing_level = float(wx_res.get('freezinglevel_height') or 0.0)

        rain_mm = float(wx_res.get('rain') or 0.0) + float(wx_res.get('showers') or 0.0)
        wmo_code = int(wx_res.get('weather_code') or 0)
        
        rain_percent = min(1.0, max(0.0, rain_mm / 8.0))
        storm_dim = 1.0 if wmo_code in [95, 96, 99] else 0.0

        spread = max(0.0, temp_c - dew_point)
        lcl_base_m = max(150.0, spread * 125.0)
        lcl_tops_m = lcl_base_m + max(1500.0, rain_mm * 250.0 + 1200.0)

        hourly_times = hourly_res.get('time', [])
        now_utc = datetime.now(timezone.utc)
        
        # 3. EXACT DATE-TIME MATCHING (Prevents grabbing yesterday's data)
        target_hour_suffix = now_utc.strftime("%Y-%m-%dT%H:00")
        h_idx = 0
        for idx, t_str in enumerate(hourly_times):
            if target_hour_suffix in t_str:
                h_idx = idx
                break

        def get_hourly_val(var_name, default=0.0, idx_override=None):
            vals = hourly_res.get(var_name, [])
            target = h_idx if idx_override is None else idx_override
            if target < len(vals) and vals[target] is not None:
                return float(vals[target])
            return default

        cloud_low = get_hourly_val('cloud_cover_low', 0.0)
        cloud_mid = get_hourly_val('cloud_cover_mid', 0.0)
        cloud_high = get_hourly_val('cloud_cover_high', 0.0)

        if cape > 800 and rain_mm > 0.2:
            cloud_type = 3
        elif cape >= 250:
            cloud_type = 2
        elif cloud_low > 50:
            cloud_type = 1
        else:
            cloud_type = 0

        past_h_idx = max(0, h_idx - 3)
        past_pressure = get_hourly_val('surface_pressure', pressure_hpa, idx_override=past_h_idx)
        qnh_trend_hpa = pressure_hpa - past_pressure

        t_850 = get_hourly_val('temperature_850hPa', temp_c)
        t_700 = get_hourly_val('temperature_700hPa', temp_c)
        t_500 = get_hourly_val('temperature_500hPa', temp_c)
        rh_850 = get_hourly_val('relative_humidity_850hPa', 50.0)

        icing_index = max(0.0, (rh_850 - 80.0) / 20.0) * math.exp(-((t_850 + 10.0) / 10.0)**2)

        base_dir = float(wx_res.get('wind_direction_10m') or 0.0)
        base_spd = float(wx_res.get('wind_speed_10m') or 2.0)
        gusts_0 = float(wx_res.get('wind_gusts_10m') or (base_spd * 1.3))

        rh_fraction = min(1.0, max(0.1, 1.0 - (spread / 25.0)))
        f_rh = 1.0 + (0.3 / max(0.05, (1.0 - rh_fraction))) * 0.15
        f_rh = max(1.0, min(f_rh, 5.0))
        
        base_extinction = 0.04
        pm25_ext = (pm25 * 0.0025) * f_rh
        dust_ext = (dust * 0.0028) * (1.0 + ((f_rh - 1.0) * 0.5))
        
        total_extinction = base_extinction + pm25_ext + dust_ext
        calc_vis_km = 3.912 / max(0.01, total_extinction)
        
        if spread <= 1.0:
            calc_vis_km = min(calc_vis_km, 0.5 + (spread * 1.5))

        weather_data = {
            "dust": dust,
            "pm10": pm10,
            "pm25": pm25,
            "dust_ceiling": round(dust_ceiling, 1),
            "qnh_inhg": round(qnh_inhg, 2),
            "qnh_trend_hpa": round(qnh_trend_hpa, 2),
            "temp_c": round(temp_c, 1),
            "dew_point": round(dew_point, 1),
            "vis_km": round(calc_vis_km, 1),
            "rain_percent": round(rain_percent, 3),
            "storm_dim": storm_dim,
            "cloud_cover": round(cloud_cover, 1),
            "cloud_low": round(cloud_low, 1),
            "cloud_mid": round(cloud_mid, 1),
            "cloud_high": round(cloud_high, 1),
            "cloud_type": cloud_type,
            "cape": round(cape, 1),
            "icing_index": round(icing_index, 3),
            "freezing_level_m": round(freezing_level, 1),
            "temp_850": round(t_850, 1),
            "temp_700": round(t_700, 1),
            "temp_500": round(t_500, 1),
            "lcl_base_m": round(lcl_base_m, 1),
            "lcl_tops_m": round(lcl_tops_m, 1),
        }

        pressure_level_mapping = {
            0: ("wind_speed_10m", "wind_direction_10m"),
            1: ("wind_speed_1000hPa", "wind_direction_1000hPa"),
            2: ("wind_speed_925hPa", "wind_direction_925hPa"),
            3: ("wind_speed_850hPa", "wind_direction_850hPa"),
            4: ("wind_speed_700hPa", "wind_direction_700hPa"),
            5: ("wind_speed_500hPa", "wind_direction_500hPa"),
            6: ("wind_speed_400hPa", "wind_direction_400hPa"),
            7: ("wind_speed_300hPa", "wind_direction_300hPa"),
            8: ("wind_speed_250hPa", "wind_direction_250hPa"),
            9: ("wind_speed_200hPa", "wind_direction_200hPa"),
            10: ("wind_speed_150hPa", "wind_direction_150hPa"),
            11: ("wind_speed_100hPa", "wind_direction_100hPa"),
            12: ("wind_speed_100hPa", "wind_direction_100hPa"),
        }

        spds = []
        dirs = []

        for i in range(13):
            spd_var, dir_var = pressure_level_mapping[i]
            if i == 0:
                w_spd = base_spd
                w_dir = int(base_dir)
            else:
                w_spd = round(get_hourly_val(spd_var, base_spd), 1)
                w_dir = int(get_hourly_val(dir_var, base_dir))

            spds.append(w_spd)
            dirs.append(w_dir)
            weather_data[f"w_dir_{i}"] = w_dir
            weather_data[f"w_spd_{i}"] = w_spd

        for i in range(13):
            if i == 0:
                gust_factor = max(0.0, (gusts_0 - spds[0]))
                shr_spd = round(gust_factor * 0.2, 4)
                shr_dir = 0.0
                turb = round(min(1.0, max(0.0, (gust_factor / 25.0))), 4)
            else:
                spd_diff = abs(spds[i] - spds[i-1])
                dir_diff = abs(dirs[i] - dirs[i-1])
                if dir_diff > 180:
                    dir_diff = 360 - dir_diff
                
                shr_spd = round(spd_diff * 0.15, 4)
                shr_dir = round(dir_diff * 0.15, 4)
                turb = round(min(1.0, max(0.0, (spd_diff / 40.0))), 4)

            weather_data[f"turb_{i}"] = turb
            weather_data[f"shr_dir_{i}"] = shr_dir
            weather_data[f"shr_spd_{i}"] = shr_spd

        return weather_data

    except Exception as e:
        print(f"API Fetch Error: {e}")
        return None

print("==================================================")
print(" All Weather Now - Live Atmospheric Bridge Running")
print(f" Monitoring Path: {SCRIPT_DIR}")
print("==================================================")

last_fetch_time = 0
last_lat = None
last_lon = None
UPDATE_INTERVAL_SEC = 300
DISTANCE_THRESHOLD_KM = 15.0
DEFAULT_LAT = 26.4300
DEFAULT_LON = 50.1000

# 4. INITIALIZE POSITION OUTSIDE LOOP (Fixes the teleportation race condition)
current_lat = DEFAULT_LAT
current_lon = DEFAULT_LON

while True:
    try:
        loc_file = os.path.join(SCRIPT_DIR, "aircraft_loc.txt")
        target_data = os.path.join(SCRIPT_DIR, "all_weather_data.txt")

        if os.path.exists(loc_file):
            try:
                with open(loc_file, "r") as f:
                    lines = f.readlines()
                    if len(lines) >= 2:
                        parsed_lat = float(lines[0].strip())
                        parsed_lon = float(lines[1].strip())
                        # Only update if safely parsed. If it fails, it keeps the old coords.
                        current_lat = parsed_lat
                        current_lon = parsed_lon
            except (ValueError, IOError):
                # Ignore read collision with FlyWithLua and retain previous coordinates
                pass

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
                print(f" ├─ Rain %: {data['rain_percent'] * 100:.1f}% | Storm Dim: {data['storm_dim']} | CAPE: {data['cape']} J/kg")
                print(f" ├─ Dynamic LCL Base: {data['lcl_base_m']} m | Tops: {data['lcl_tops_m']} m | Cloud Type: {data['cloud_type']}")
                print(f" ├─ Dust: {data['dust']} µg/m³ | PM2.5: {data['pm25']} µg/m³ | Loft Ceiling: {data['dust_ceiling']} m | Calc Vis: {data['vis_km']} km")
                print(f" ├─ Clouds ➔ Total: {data['cloud_cover']}% | Low: {data['cloud_low']}% | Mid: {data['cloud_mid']}% | High: {data['cloud_high']}%")
                print(f" ├─ QNH: {data['qnh_inhg']} inHg (Trend: {data['qnh_trend_hpa']} hPa) | Temp: {data['temp_c']}°C | DewPoint: {data['dew_point']}°C")
                print(f" ├─ Upper Air Temps ➔ 850hPa: {data['temp_850']}°C | 700hPa: {data['temp_700']}°C | 500hPa: {data['temp_500']}°C")
                print(f" ├─ Icing Index: {data['icing_index']} | Freezing Level: {data['freezing_level_m']} m")
                print(f" └─ Surface Wind (10m): {data['w_dir_0']:03d}° / {data['w_spd_0']} m/s")
                print("-" * 65)
                
                temp_target = target_data + ".tmp"
                with open(temp_target, "w") as out:
                    for key, val in data.items():
                        out.write(f"{key}={val}\n")
                os.replace(temp_target, target_data)
                
                last_fetch_time = current_time
                last_lat = current_lat
                last_lon = current_lon

    except Exception as outer_e:
        print(f"[LOOP EXCEPTION RECOVERED]: {outer_e}")

    time.sleep(5)