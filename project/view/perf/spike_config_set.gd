class_name SpikeConfigSet
extends Resource
## SE-003 성능 스파이크 설정 전체: 구성 A~D, 측정 절차(예열·측정 시간, 해상도, 관문), 군중·라이트 연출 상수.
## 렌더 측정 설정이라 data/ 가 아닌 view 리소스(spike_configs.tres)에 둔다. 코드에는 숫자를 두지 않는다.

# --- 구성 -----------------------------------------------------------------

## 측정 구성들(티켓 표 A~D).
@export var configs: Array[SpikeConfig] = []
## --config 가 없을 때 쓰는 구성 id.
@export var default_config_id: String = ""

# --- 측정 절차 ------------------------------------------------------------

## 관문 판정 대상 구성 id(티켓: B).
@export var gate_config_id: String = ""
## 관문: 이 구성의 평균 fps 가 이 값 이상이면 통과(PRD: 60fps).
@export var gate_min_avg_fps: float = 0.0
## 측정 전 예열 시간(초). warmup_min_frames 도 함께 채워야 예열이 끝난다.
@export var warmup_sec: float = 0.0
## 예열 최소 프레임 수(셰이더 컴파일·파이프라인 캐시가 끝나도록).
@export var warmup_min_frames: int = 0
## 프레임 시간 수집 시간(초).
@export var measure_sec: float = 0.0
## 측정 창 크기(px). 군중 배치 영역도 이 화면비로 맞춘다.
@export var resolution: Vector2i = Vector2i.ZERO

# --- 군중(캐릭터 프록시) --------------------------------------------------

## 군중 정사각 영역 한 변 = (최대 줌아웃 화면에 들어가는 최대 한 변) × 이 비율. 1 미만이라야 흔들림 여유가 생긴다.
@export var crowd_fill_ratio: float = 0.0
## 배치 지터: 격자 간격 대비 비율(0 = 정확한 격자).
@export var crowd_jitter_ratio: float = 0.0
## 배치·색·위상 RNG 시드(재현성).
@export var crowd_seed: int = 0
## 프록시 몸통 캡슐 반지름·높이(m), 분할 수. 기본값은 style-guide 캐릭터 예산(≤ 800 tri) 근처의 최악 비용.
@export var body_radius_m: float = 0.0
@export var body_height_m: float = 0.0
@export var body_radial_segments: int = 0
@export var body_rings: int = 0
## 머리 박스 한 변(m). 몸통 꼭대기 위에 얹는다.
@export var head_size_m: float = 0.0
## 팔 박스 크기(m, x·y·z). 몸통 양옆에 하나씩.
@export var arm_size_m: Vector3 = Vector3.ZERO
## 인스턴스 색 팔레트(인스턴스마다 하나 고름).
@export var crowd_palette: PackedColorArray = PackedColorArray()
## 시뮬레이션 위치 갱신 빈도(Hz). 렌더는 틱 사이를 보간한다(CLAUDE.md 고정 틱 10 tick/s 와 같은 경로를 흉내).
@export var interpolation_tick_hz: float = 0.0
## 인스턴스가 기준점 주위를 배회하는 반지름(m)과 각속도 범위(rad/s, 인스턴스마다 균등 분포).
@export var wander_radius_m: float = 0.0
@export var wander_speed_min: float = 0.0
@export var wander_speed_max: float = 0.0
## 상하 흔들림(점프/바운스) 높이(m)와 빈도(Hz).
@export var bob_height_m: float = 0.0
@export var bob_freq_hz: float = 0.0

# --- 라이트 ---------------------------------------------------------------

## 라이트 기준 높이(m).
@export var light_height_m: float = 0.0
## 라이트 배치 영역 = 군중 영역 × 이 비율(가장자리 라이트가 군중을 비추도록).
@export var light_area_ratio: float = 0.0
## 라이트가 기준점 주위를 도는 반지름(m)과 각속도(rad/s).
@export var light_orbit_radius_m: float = 0.0
@export var light_orbit_speed: float = 0.0
## 색상(hue) 순환 속도(회/초)와 채도.
@export var light_hue_speed: float = 0.0
@export var light_saturation: float = 0.0
@export var omni_range_m: float = 0.0
@export var omni_energy: float = 0.0
@export var spot_range_m: float = 0.0
@export var spot_angle_deg: float = 0.0
@export var spot_energy: float = 0.0
## 무빙 헤드: 스폿이 바닥에서 겨누는 점이 기준점 주위를 도는 반지름(m)과 각속도(rad/s).
@export var spot_sweep_radius_m: float = 0.0
@export var spot_sweep_speed: float = 0.0


func get_config(config_id: String) -> SpikeConfig:
	for c: SpikeConfig in configs:
		if c.id == config_id:
			return c
	return null


func get_config_ids() -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray()
	for c: SpikeConfig in configs:
		ids.append(c.id)
	return ids


## 전체 설정의 문제 목록(빈 배열 = 유효).
func get_errors() -> PackedStringArray:
	var errs: PackedStringArray = PackedStringArray()
	var seen: Dictionary = {}
	for c: SpikeConfig in configs:
		if c == null:
			errs.append("configs 에 null 항목")
			continue
		errs.append_array(c.get_errors())
		if seen.has(c.id):
			errs.append("구성 id 중복: %s" % c.id)
		seen[c.id] = true
	if configs.is_empty():
		errs.append("configs 가 비어 있다")
	if get_config(default_config_id) == null:
		errs.append("default_config_id 가 configs 에 없다: %s" % default_config_id)
	if get_config(gate_config_id) == null:
		errs.append("gate_config_id 가 configs 에 없다: %s" % gate_config_id)
	if gate_min_avg_fps <= 0.0:
		errs.append("gate_min_avg_fps > 0")
	if warmup_sec < 0.0 or warmup_min_frames < 0:
		errs.append("예열 값은 0 이상")
	if measure_sec <= 0.0:
		errs.append("measure_sec > 0")
	if resolution.x <= 0 or resolution.y <= 0:
		errs.append("resolution 양수")
	if crowd_fill_ratio <= 0.0 or crowd_fill_ratio >= 1.0:
		errs.append("0 < crowd_fill_ratio < 1")
	if crowd_jitter_ratio < 0.0 or crowd_jitter_ratio >= 0.5:
		errs.append("0 ≤ crowd_jitter_ratio < 0.5")
	if body_radius_m <= 0.0 or body_height_m <= 2.0 * body_radius_m:
		errs.append("몸통: 반지름 > 0, 높이 > 2×반지름")
	if body_radial_segments < 4 or body_rings < 1:
		errs.append("몸통 분할 수 부족")
	if head_size_m <= 0.0 or arm_size_m.x <= 0.0 or arm_size_m.y <= 0.0 or arm_size_m.z <= 0.0:
		errs.append("머리·팔 크기 양수")
	if crowd_palette.is_empty():
		errs.append("crowd_palette 비어 있음")
	if interpolation_tick_hz <= 0.0:
		errs.append("interpolation_tick_hz > 0")
	if wander_radius_m <= 0.0 or wander_speed_min <= 0.0 or wander_speed_max < wander_speed_min:
		errs.append("배회: 반지름 > 0, 0 < 최소 속도 ≤ 최대 속도 (모든 인스턴스가 매 프레임 움직여야 한다)")
	if bob_height_m < 0.0 or bob_freq_hz < 0.0:
		errs.append("흔들림 값은 0 이상")
	if light_height_m <= body_height_m + head_size_m:
		errs.append("light_height_m 는 캐릭터보다 높아야 한다")
	if light_area_ratio <= 0.0 or light_orbit_radius_m <= 0.0 or light_orbit_speed <= 0.0:
		errs.append("라이트 배치·궤도 값 양수 (모든 라이트가 매 프레임 움직여야 한다)")
	if omni_range_m <= 0.0 or spot_range_m <= 0.0 or spot_angle_deg <= 0.0 or spot_angle_deg >= 90.0:
		errs.append("라이트 범위·스폿 각도")
	return errs
