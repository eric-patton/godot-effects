extends RefCounted
## The scene's mood presets — ONE Dictionary per look, every key the world can apply
## (see red_sea.gd's apply_mood_values). DAY / NIGHT_STORM are the baked sandbox values
## (DAY must stay equal to the _build_environment baseline: toggling back to day restores it).
## DUSK and DAWN bookend the game's night crossing: approach at dusk, storm-night for the
## crossing, dawn for the sea's return ("when the morning appeared", Exodus 14:27).
##
## rain / lightning are 0/1 step values: blended like everything else but only ever READ at
## the endpoints of a transition (the MoodController toggles the systems there).

const KEYS := [
	"ambient", "glow", "glow_thresh",
	"vfog_density", "vfog_albedo", "vfog_emission", "vfog_inject",
	"fog_density", "fog_light",
	"sun_color", "sun_energy", "sun_beam", "sun_pitch", "sun_yaw",
	"sky_zenith", "sky_horizon", "sky_ground", "ground_tint", "sky_night",
	"rain", "lightning",
]

const DAY := {
	"ambient": 0.6, "glow": 0.30, "glow_thresh": 1.3,
	"vfog_density": 0.02, "vfog_albedo": Color(0.85, 0.92, 1.0),
	"vfog_emission": Color(0.05, 0.08, 0.12), "vfog_inject": 0.4,
	"fog_density": 0.014, "fog_light": Color(0.78, 0.82, 0.85),
	"sun_color": Color(1.0, 0.94, 0.82), "sun_energy": 1.2, "sun_beam": 3.0,
	"sun_pitch": -90.0, "sun_yaw": 0.0,    # noon: straight down (view-independent lighting)
	"sky_zenith": Color(0.32, 0.50, 0.82), "sky_horizon": Color(0.78, 0.82, 0.85),
	"sky_ground": Color(0.7, 0.7, 0.66), "ground_tint": Color(0.70, 0.66, 0.55),
	"sky_night": 0.0, "rain": 0.0, "lightning": 0.0,
}

# Approach at sunset: warm low sun over the water, first stars, the calm before the storm.
const DUSK := {
	"ambient": 0.34, "glow": 0.36, "glow_thresh": 1.15,
	"vfog_density": 0.025, "vfog_albedo": Color(0.75, 0.62, 0.55),
	"vfog_emission": Color(0.04, 0.03, 0.03), "vfog_inject": 0.32,
	"fog_density": 0.018, "fog_light": Color(0.55, 0.40, 0.34),
	"sun_color": Color(1.0, 0.58, 0.32), "sun_energy": 0.85, "sun_beam": 2.6,
	"sun_pitch": -9.0, "sun_yaw": -125.0,  # low across the open sea, long warm rakes
	"sky_zenith": Color(0.16, 0.18, 0.38), "sky_horizon": Color(0.95, 0.52, 0.28),
	"sky_ground": Color(0.30, 0.22, 0.18), "ground_tint": Color(0.52, 0.40, 0.32),
	"sky_night": 0.15, "rain": 0.0, "lightning": 0.0,
}

# The crossing: cold raking moonlight, rain + sheet lightning. (The sandbox's night look.)
const NIGHT_STORM := {
	"ambient": 0.14, "glow": 0.55, "glow_thresh": 0.90,
	"vfog_density": 0.045, "vfog_albedo": Color(0.22, 0.28, 0.42),
	"vfog_emission": Color(0.01, 0.012, 0.02), "vfog_inject": 0.22,
	"fog_density": 0.030, "fog_light": Color(0.06, 0.08, 0.13),
	"sun_color": Color(0.55, 0.66, 0.95), "sun_energy": 0.34, "sun_beam": 2.4,
	"sun_pitch": -52.0, "sun_yaw": 28.0,   # raking moon -> long shadows down the corridor
	"sky_zenith": Color(0.015, 0.022, 0.045), "sky_horizon": Color(0.05, 0.07, 0.11),
	"sky_ground": Color(0.04, 0.05, 0.07), "ground_tint": Color(0.05, 0.06, 0.08),
	"sky_night": 1.0, "rain": 1.0, "lightning": 1.0,
}

# Morning breaks beyond the FAR (+z) shore as the sea returns: golden light raking back
# over the water toward the camera (sun_yaw 180), storm spent.
const DAWN := {
	"ambient": 0.42, "glow": 0.34, "glow_thresh": 1.1,
	"vfog_density": 0.022, "vfog_albedo": Color(0.95, 0.80, 0.62),
	"vfog_emission": Color(0.05, 0.04, 0.03), "vfog_inject": 0.35,
	"fog_density": 0.016, "fog_light": Color(0.80, 0.62, 0.45),
	"sun_color": Color(1.0, 0.74, 0.48), "sun_energy": 1.0, "sun_beam": 2.8,
	"sun_pitch": -12.0, "sun_yaw": 180.0,
	"sky_zenith": Color(0.30, 0.42, 0.66), "sky_horizon": Color(1.0, 0.72, 0.45),
	"sky_ground": Color(0.45, 0.36, 0.28), "ground_tint": Color(0.62, 0.52, 0.42),
	"sky_night": 0.0, "rain": 0.0, "lightning": 0.0,
}


static func blend(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var out := {}
	for k in KEYS:
		var av: Variant = a[k]
		if av is Color:
			out[k] = (av as Color).lerp(b[k], t)
		else:
			out[k] = lerpf(av, b[k], t)
	return out
