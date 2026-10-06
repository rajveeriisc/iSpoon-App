/*
 * I SPOON — production firmware v2.1
 *
 *   Touch + animated splash + temperature display
 * + BMI270 bite counter (Zephyr sensor driver)
 * + 100 Hz IMU streaming over BLE (double-buffered, dedicated TX thread)
 * + nPM1300 battery monitor (non-blocking measurement)
 * + Fitness-band style BLE connection management:
 *       - Always reconnectable while the device is ON
 *       - Fast advertising (30-60 ms) for 30 s after power-on / disconnect,
 *         then slow advertising (1-1.2 s) indefinitely -> phone can
 *         background-reconnect at any time, minimal battery cost
 *       - Advertising is managed by a single work item on the system
 *         workqueue: restart-after-disconnect is retried automatically
 *         (fixes the classic -ENOMEM "dead until reboot" failure)
 *       - Connection: 30-50 ms interval + slave latency 4, 2M PHY,
 *         data length extension, MTU exchange initiated by us
 *       - Connection object is reference-counted through a mutex-guarded
 *         acquire/release API: no use-after-free between the BT RX
 *         thread and the TX thread
 *       - Clean shutdown: disconnect is confirmed (semaphore) before
 *         System OFF, so the phone sees a proper termination instead of
 *         a 4 s supervision timeout
 *
 * UI / power:
 *   Double-tap      -> wake confirm from System OFF (splash + UI + BLE),
 *                      or clean shutdown to System OFF while running.
 *   Long hold 6 s   -> clear owner BLE bond (physical presence only).
 *
 * Target: nRF52840, NCS v3.3.1 (Zephyr int main()).
 *
 * ============================================================
 * BLE DATA PROTOCOL (single notification, little-endian, 129 B)
 * ============================================================
 *
 *   offset  size  field          notes
 *   0       1     battery        %, 0-100
 *   1       2     temperature    int16, degC x 100 (NTC)
 *   3       4     timestamp_ms   uint32, uptime of the FIRST sample
 *                                in this batch (not send time)
 *   7       2     bite_count     uint16
 *   9       120   samples[10]    10 x ImuSample (12 B each), 10 ms apart
 *
 *   ImuSample: int16 ax,ay,az (milli-g), int16 gx,gy,gz (0.1 deg/s)
 *              gyro range covers ±2000 dps BMI270 FS without silent clip
 *
 *   Sent every 100 ms while bulk CCC is subscribed.
 *   Requires ATT MTU >= 132. We initiate the MTU exchange.
 *
 * EVENT NOTIFY (f00d0007) — low rate for iOS background (~11 B):
 *   0     1  version       = 1
 *   1     1  battery       %
 *   2     2  temperature   int16 °C×100 (INT16_MIN = NTC invalid)
 *   4     2  bite_count    uint16
 *   6     1  flags         bit0 VBUS, bit1 charging, bit2 NTC ok,
 *                          bit3 IMU healthy, bit4 meal_active (reserved)
 *   7     4  timestamp_ms  uint32 uptime
 *   Cadence: on change, and at least every 30 s while event CCC is on.
 *
 * ============================================================
 * REQUIRED prj.conf ADDITIONS (see prj.conf.snippet)
 * ============================================================
 *   CONFIG_BT_GATT_CLIENT=y             (bt_gatt_exchange_mtu)
 *   CONFIG_BT_USER_PHY_UPDATE=y         (2M PHY request)
 *   CONFIG_BT_USER_DATA_LEN_UPDATE=y    (DLE request)
 *   CONFIG_BT_L2CAP_TX_MTU=498
 *   CONFIG_BT_BUF_ACL_TX_SIZE=502
 *   CONFIG_BT_BUF_ACL_RX_SIZE=502
 *   CONFIG_BT_ATT_TX_COUNT=6
 *   CONFIG_BT_CONN_TX_MAX=6
 *   CONFIG_BT_BUF_ACL_TX_COUNT=6
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/spi.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/drivers/adc.h>
#include <zephyr/drivers/i2c.h>
#include <zephyr/drivers/sensor.h>
#include <zephyr/drivers/sensor/npm13xx_charger.h>
#include <zephyr/drivers/watchdog.h>
#include <zephyr/drivers/hwinfo.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/poweroff.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/logging/log.h>
#include <zephyr/settings/settings.h>
#include <zephyr/dfu/mcuboot.h>

#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/services/bas.h>
#include <zephyr/bluetooth/services/bas.h>

#include <zephyr/mgmt/mcumgr/mgmt/callbacks.h>
#include <zephyr/mgmt/mcumgr/mgmt/mgmt_defines.h>
#include <zephyr/mgmt/mcumgr/grp/img_mgmt/img_mgmt_callbacks.h>
#include <zephyr/mgmt/mcumgr/grp/os_mgmt/os_mgmt_callbacks.h>

#include <hal/nrf_gpio.h>

#include <math.h>
#include <string.h>
#include <limits.h>
#include <stdio.h>
#include <stdbool.h>
#include <nrfx_saadc.h>

LOG_MODULE_REGISTER(spoon, LOG_LEVEL_INF);

/* =====================================================================
 *  BUILD TOGGLES — sab ek jagah. Sirf 0/1 badalna hota hai.
 *  (Definitions apni-apni section mein hain; ye sirf reference hai.)
 *
 *    THEME_DARK          1  black bg + white text (acrylic ke liye)
 *                        0  white bg + black text (panel verify)
 *    NTC_DIAG_ON_SCREEN  1  boot par 8 s ADC diagnostic page dikhao
 *                        0  seedha normal UI (temp theek hone ke baad)
 *    NTC_MATH_V1         1  original firmware ka EXACT temp math
 *                        0  corrected math (ADC 3.6 V FS + V_SUPPLY rail)
 *    DEBUG_FORCE_ON      0  production (wake ON, double-tap OFF)
 *                        1  always on, ignore double-tap OFF (bench)
 *
 *  PRODUCTION: NTC_DIAG_ON_SCREEN 0, DEBUG_FORCE_ON 0,
 *  baaki jaise temperature sahi aati hai (NTC_MATH_V1 rakh sakte ho).
 * ===================================================================== */

/* ================= DISPLAY CONFIG ================= */

#define TFT_VISIBLE_W   160
#define TFT_VISIBLE_H    80
#define TFT_GRAM_W      162
#define TFT_GRAM_H      132
#define TFT_X_OFFSET      1
#define TFT_Y_OFFSET     26

/*
 * Acrylic / CAD window over the panel (mm): 22.70 × 10.00, corner R4.00.
 * Framebuffer is 160×80, so:
 *   px_x = 22.70/160 ≈ 0.142 mm    R_x ≈ 28 px
 *   px_y = 10.00/80  = 0.125 mm    R_y = 32 px
 * Pixels in the four R4 fillets are hidden. A status glyph at (2,0) is
 * inside the top-left fillet and never reaches the user. Inset the UI
 * so every glyph stays in the opening; at y≈6 the fillet still needs
 * ~12 px of left/right margin.
 */
#define UI_INSET_X     12
#define UI_INSET_Y      6
#define UI_SAFE_X0     UI_INSET_X
#define UI_SAFE_Y0     UI_INSET_Y
#define UI_SAFE_X1     (TFT_VISIBLE_W - UI_INSET_X)
#define UI_SAFE_Y1     (TFT_VISIBLE_H - UI_INSET_Y)
#define UI_SAFE_W      (UI_SAFE_X1 - UI_SAFE_X0)

#define TFT_CS_PIN   12
#define TFT_DC_PIN   11
#define TFT_RST_PIN  10
#define LED_PIN      14

#define SPI_NODE     DT_NODELABEL(spi3)
#define SCALE        3

/* --- THEME SWITCH ---
 * THEME_DARK 1 = black bg / white text (for the black acrylic cover).
 * THEME_DARK 0 = v1's white bg / black text — flash with 0 to VERIFY
 * the panel: if the screen glows white like the old build, the
 * display path is fine and the "dark screen" was just the black
 * theme being invisible through the acrylic before the splash. */
#define THEME_DARK   1
/*
 * Factory default for the glass currently fitted. VERIFIED ON HARDWARE
 * 2026-09-07: this panel does NOT natively invert, so it needs INVOFF (0).
 * With INVON(1) the whole theme flipped — white background, black text,
 * and every colour complemented (low-battery red 0xF800 showed as cyan
 * 0x07FF). 1 = the other glass variant, which does natively invert.
 * This is only the DEFAULT — see panel_invert for the runtime override.
 */
#define TFT_PANEL_INVON  0

#if THEME_DARK
#define COLOR_BG     0x0000              /* black  */
#define COLOR_FG     0xFFFF              /* white  */
#define COLOR_BT     0x07E0              /* bright green — BLE connected */
#define COLOR_GREEN  0x07E0              /* bright green — charging / BT */
#else
#define COLOR_BG     0xFFFF              /* white  (v1 theme) */
#define COLOR_FG     0x0000              /* black  */
#define COLOR_BT     0x0400              /* green — BLE connected */
#define COLOR_GREEN  0x0400              /* dark green — charging */
#endif
#define COLOR_RED    0xF800              /* red — battery low */

/* ---- Panel polarity: RUNTIME, not compile-time ----
 *
 * Two glass variants ship on this product: one paints 0x0000 as black
 * (needs INVOFF) and one natively inverts, painting 0x0000 as WHITE (needs
 * INVON to look dark). Getting it wrong flips the whole theme -- white
 * background with dark text -- and also swaps every colour, so the low
 * battery warning shows cyan instead of red and BLE/charging shows magenta
 * instead of green.
 *
 * It CANNOT be auto-detected: the panel SPI is deliberately write-only
 * (MISO is unrouted so no analog pin is claimed), so the glass never
 * answers an ID read. So it is a persisted setting instead:
 *
 *   - TFT_PANEL_INVON is only the FACTORY DEFAULT for a fresh unit.
 *   - A board with the other glass is corrected once, over BLE, with
 *     "INV 0" / "INV 1" -- no rebuild, no reflash.
 *   - It lives in the settings partition, so a normal (no mass-erase)
 *     reflash keeps it, and every later boot paints correctly from the
 *     very first frame.
 */
static uint8_t panel_invert = TFT_PANEL_INVON;

/* BLE thread parks a request here; the UI thread applies it. -1 = none. */
static atomic_t panel_invert_req = ATOMIC_INIT(-1);

static int panel_settings_set(const char *name, size_t len,
                              settings_read_cb read_cb, void *cb_arg)
{
    if (settings_name_steq(name, "inv", NULL) && len == sizeof(panel_invert)) {
        uint8_t v;
        if (read_cb(cb_arg, &v, sizeof(v)) > 0) {
            panel_invert = v ? 1U : 0U;
            return 0;
        }
    }
    return -ENOENT;
}

SETTINGS_STATIC_HANDLER_DEFINE(ispoon_panel, "ispoon", NULL,
                               panel_settings_set, NULL, NULL);

#define BATT_LOW_PCT      20

/* ================= TOUCH CONFIG ================= */

#define TOUCH_PIN          16

/*
 * Power control (TTP223 + handle wire) — double-tap OFF
 *   ON  — System OFF wakes on pad HIGH
 *   OFF — two clean taps while running (single tap ignored)
 *
 * Tuned for TTP223 + wire: wider time windows, light debounce,
 * bounce does not wipe a good first tap, no long cooldown after a
 * lonely single (so a second try works immediately).
 */
#define TOUCH_POLL_MS             8
#define TOUCH_CONSENSUS_N         3     /* ~24 ms — TTP223 already filters */
#define TOUCH_TAP_MIN_MS          25    /* reject EMI spikes only */
#define TOUCH_TAP_MAX_MS          450   /* allow normal / firm presses */
#define TOUCH_INTER_TAP_MIN_MS    40    /* min release between taps */
#define TOUCH_DOUBLE_GAP_MS       700   /* max time after tap1 for tap2 */
#define TOUCH_COOLDOWN_MS         900   /* after successful double-tap OFF */
#define TOUCH_OFF_ARM_MS          900   /* ignore OFF right after boot */
#define TOUCH_BOOT_TIMEOUT_MS     10000

/* Optional IMU backup if pad stuck (secondary path). */
#define KNOCK_ON_G                2.10f
#define KNOCK_OFF_G               1.35f
#define KNOCK_MIN_MS              12
#define KNOCK_MAX_MS              160
#define KNOCK_GAP_MIN_MS          70
#define KNOCK_GAP_MAX_MS          600
#define KNOCK_COOLDOWN_MS         1000

#define LETTER_STEP_MS     60
#define SPLASH_HOLD_MS     800    /* brief ISPOON PRO, then always TEMP */

#define LOOP_MS            50         /* UI refresh period (touch polls faster) */

/* Production: 0 = double-tap OFF + System OFF + touch wake.
 * Set 1 only for bench (always on, ignore OFF). */
#define DEBUG_FORCE_ON     0

/* ================= ADC / NTC CONFIG ================= */

#define FILTER_LEN         8
#define HYSTERESIS_C       0.5f

/* SAADC configured with gain 1/6 and the 0.6 V internal reference:
 * full scale at the pin = 0.6 * 6 = 3.6 V. THIS is the conversion
 * scale for raw codes — NOT the NTC divider supply. (v1 used 2.8 V
 * here, which under-read the pin voltage by ~22% and biased the
 * temperature low — the 55 C safety trip fired late.)
 *
 * DO NOT set this to 4.2 V. Battery charge termination (4.20 V) is
 * configured on the nPM1300 in boards/...overlay (term-microvolt)
 * and in npm_battery_percent(). This constant is only for the heater
 * NTC on SAADC AIN0. */
#define ADC_FULL_SCALE_V   3.6f

/* --- NTC MATH COMPATIBILITY SWITCH ---
 * 1 = EXACT computation of the original firmware ("main__3_.c"):
 *     v = raw * 2.8 / 4095 and r = 10k*(2.8/v - 1). Bit-for-bit the
 *     same temperature the old build produced on the same raw counts
 *     (its two 2.8 errors cancel into an effective 3.6 V-supply
 *     model, ~4 C low at room temp but "working").
 * 0 = corrected math (3.6 V full-scale, V_SUPPLY divider rail).
 * If the display STILL reads negative with this set to 1, the raw
 * ADC counts themselves are low -> hardware (NTC rail or the
 * NTC connector path), proven beyond any firmware doubt. */
#define NTC_MATH_V1        0

/* ================= BMI270 (Zephyr sensor driver) =================
 * PCB uses Bosch BMI270 on I2C0 @ 0x68 (see boards/ overlay).
 * Do NOT use the old BMI323 bare-metal register driver — chip ID,
 * register map and dummy-byte protocol are completely different, so
 * BLE would never get valid IMU samples. */

#define I2C_NODE                DT_NODELABEL(i2c0)

#define IMU_ACC_RANGE_G         8
#define IMU_GYR_RANGE_DPS       2000
#define IMU_ODR_HZ              100

/* ================= nPM1300 ================= */

#define NPM_ADDR                0x6B
#define NPM_BASE_VBUS           0x02
#define NPM_BASE_CHG            0x03
#define NPM_BASE_ADC            0x05
#define NPM_REG_TASKUPDATEILIM  0x00
#define NPM_REG_VBUSINILIM0     0x01
#define NPM_REG_VBUSINSTATUS    0x07
#define NPM_REG_BCHGENABLESET   0x04
#define NPM_REG_BCHGENABLECLR   0x05
#define NPM_REG_BCHGISET        0x08
#define NPM_REG_BCHGVTERM       0x0C
#define NPM_REG_BCHGVTERMR      0x0D
#define NPM_REG_BCHGCHARGESTATUS 0x34
#define NPM_REG_BCHGERRREASON   0x36
#define NPM_REG_BCHGERRSENSOR   0x37
#define NPM_REG_TASKVBATMEAS    0x00
#define NPM_REG_ADCNTCRSEL      0x0A
#define NPM_REG_ADCVBATMSB      0x11
#define NPM_REG_ADCGP0LSBS      0x15

#define NPM_CHGSTAT_BATTDET     BIT(0)
#define NPM_CHGSTAT_COMPLETE    BIT(1)
#define NPM_CHGSTAT_TRICKLE     BIT(2)
#define NPM_CHGSTAT_CC          BIT(3)
#define NPM_CHGSTAT_CV          BIT(4)
#define NPM_CHGSTAT_CHARGING    (NPM_CHGSTAT_TRICKLE|NPM_CHGSTAT_CC|NPM_CHGSTAT_CV)
/* nPM13xx VBUSINSTATUS bit0 = VBUS present (USB / charger plugged). */
#define NPM_VBUS_PRESENT        BIT(0)
#define BATT_POLL_MS            2000
#define VBAT_CONV_TIME_MS       15     /* ADC conversion settle before read */
/* Debounce plug/charge UI so CC<->CV or brief status glitches do not
 * look like "connecting / disconnecting" on the status bar. */
#define CHG_UI_DEBOUNCE_SAMPLES 2

#define SOC_TRANSIENT_SAMPLES   6
#define SOC_SLEW_MAX_PCT        1

/* Pack internal resistance (mOhm) at the PMIC's VBAT sense point: cell ESR +
 * protection FET + wiring. Charging pushes the terminal voltage UP by I*R and
 * load pulls it DOWN by I*R, so a voltage-only gauge reads high while charging
 * and drops the moment the charger is unplugged. We convert the loaded reading
 * into an open-circuit estimate before mapping it to a percentage.
 *
 * CALIBRATE FOR YOUR CELL: note VBAT while charging at a known current, then
 * unplug and read VBAT again within ~1 s (before the cell relaxes):
 *     R_mOhm = (V_charging_mV - V_unplugged_mV) * 1000 / I_charge_mA
 * 200 mOhm is a typical small LiPo + protection-circuit starting point. At
 * 500 mA that is a 100 mV correction, which is ~10 %% on the curve below. */
#define BATT_IR_MOHM            200

#define PMIC_DEBUG_VIEW   0

/* ================= TPS628682A (heater rail) =================
 *
 * Stuffed part is TPS628682A (0.8–3.35 V, 10 mV). Schematic
 * I_spoon_heater.pdf labels U1 TPS628681ARQYR — that sheet is wrong;
 * do not program the 681A 1.675 V range.
 *
 * EN pin P0.15 active HIGH. I2C address from R18 on VSET/VID
 * (249 kΩ → 0x46, 12.1 kΩ → 0x40). Try both.
 * Boot: EN stays LOW. Every OFF→ON: EN HIGH, VOUT 0xE6 (3.10 V),
 * verify, fail OFF on any error.
 *
 * BLE RX commands:
 *   "ON"      heater on for at most 5 min, or until OFF / disconnect
 *   "ON XX"   heater on until NTC >= XX °C, at most 10 min
 *   "OFF"     heater off immediately
 */
#define TPS_ADDR          0x46  /* R18 249 kΩ */
#define TPS_ADDR_ALT      0x40  /* R18 12.1 kΩ */
static uint8_t tps_i2c_addr = TPS_ADDR;
#define TPS_EN_PIN        15
#define TPS_REG_VOUT      0x01
#define TPS_REG_STATUS    0x05
#define TPS_VOUT_3V10     0xE6      /* 682A: 0.800 + 230*0.010 = 3.10 V */
#define TPS_EN_SETTLE_US  1200
#define TPS_STATUS_THERMAL_WARN BIT(4)
#define TPS_STATUS_HICCUP       BIT(3)
#define TPS_STATUS_UVLO         BIT(0)
#define TPS_STATUS_FAULT_MASK   (TPS_STATUS_THERMAL_WARN | \
                                 TPS_STATUS_HICCUP | TPS_STATUS_UVLO)

/* The heater supervisor is independent of the display/UI state. */
#define HEATER_SETPOINT_MIN_C       30
#define HEATER_SETPOINT_MAX_C       70
#define HEATER_HARD_LIMIT_C         75.0f
#define HEATER_HYSTERESIS_C         5.0f
#define HEATER_NO_TARGET_MAX_MS     (5U * 60U * 1000U)
#define HEATER_TARGET_MAX_MS        (10U * 60U * 1000U)
#define HEATER_BURST_COOLDOWN_MS    5000U
#define NTC_RAW_VALID_MIN           50
#define NTC_RAW_VALID_MAX           4000
#define NTC_VALID_SAMPLES_REQUIRED  3
#define HEATER_SAFETY_PERIOD_MS     50U
#define PMIC_SAFETY_POLL_MS         250U
#define TPS_STATUS_POLL_MS          100U
#define HEATER_BATTERY_START_MIN_MV 3500U
#define HEATER_BATTERY_HARD_MIN_MV  3300U
#define HEATER_RATE_WINDOW_MS       1000U
#define HEATER_MAX_RISE_C_PER_S     20.0f
#define HEATER_NO_RISE_WINDOW_MS    45000U
#define HEATER_MIN_RISE_C           1.0f
#define HEATER_SAFETY_STACK_SIZE    2048
#define HEATER_SAFETY_PRIORITY      -1

/* Unowned devices always allow new pairing. Owned devices reject new
 * peers until a 6 s physical long-hold clears the owner bond. */
#define ISPOON_BT_ID                1U
/* Long continuous hold while ON clears the owner bond (not double-tap). */
#define OWNER_RESET_HOLD_MS         6000U
#define MAIN_WATCHDOG_TIMEOUT_MS    5000U
#define IMAGE_HEALTH_DWELL_MS       10000U
#define IMAGE_VALIDATION_TIMEOUT_MS 60000U

/* ================= GLOBALS ================= */

static const struct device *spi_dev;
static const struct device *gpio0;
static const struct device *gpio1;
static const struct device *i2c_dev;
static const struct device *imu_dev;
static const struct device *charger_dev;
static const struct device *watchdog_dev;
static const struct adc_dt_spec heater_adc_channel =
    ADC_DT_SPEC_GET(DT_PATH(zephyr_user));

/* Written by BLE RX callback; ON actuation is owned by the safety supervisor. */
static atomic_t heater_on_atomic     = ATOMIC_INIT(0);
static atomic_t heater_setpoint_c    = ATOMIC_INIT(0);  /* 0 = no cutoff */
static atomic_t heater_fault_atomic  = ATOMIC_INIT(0);
static atomic_t ntc_valid_atomic     = ATOMIC_INIT(0);
static atomic_t battery_status_valid = ATOMIC_INIT(0);
static atomic_t tps_ready_atomic     = ATOMIC_INIT(0);
static atomic_t tps_rail_state       = ATOMIC_INIT(0);
static atomic_t pmic_ready_atomic    = ATOMIC_INIT(0);
static atomic_t adc_ready_atomic     = ATOMIC_INIT(0);

/* Shared scalar state for the BLE packet and the safety supervisor. */
static atomic_t shared_battery_pct   = ATOMIC_INIT(0);
static atomic_t shared_temp_c100     = ATOMIC_INIT(0);
static atomic_t shared_bite_count    = ATOMIC_INIT(0);

static atomic_t ble_secured          = ATOMIC_INIT(0);
static atomic_t owner_bond_present   = ATOMIC_INIT(0);
/* Set when pairing_accept rejects a new peer while an owner bond exists.
 * Readable via open owner_status GATT char so the app can prompt 6 s hold. */
static atomic_t pair_reject_latched  = ATOMIC_INIT(0);
static atomic_t pair_reject_reason   = ATOMIC_INIT(0);
/* DFU lock: blocks heater ON while an image upload is active or a TEST
 * image is staged. Cleared only on abort (STOPPED without PENDING). */
static atomic_t dfu_locked_atomic    = ATOMIC_INIT(0);
static atomic_t dfu_pending_atomic   = ATOMIC_INIT(0);
/* Last converted IMU sample (milli-g) for health / fail-over stream. */
static atomic_t imu_last_ax_mg       = ATOMIC_INIT(0);
static atomic_t imu_last_ay_mg       = ATOMIC_INIT(0);
static atomic_t imu_last_az_mg       = ATOMIC_INIT(0);
static atomic_t imu_sample_ok_count  = ATOMIC_INIT(0);
static atomic_t imu_sample_err_count = ATOMIC_INIT(0);
/* Set by imu_thread on double-knock; main/soft-off clears with cas. */
static atomic_t knock_double_event   = ATOMIC_INIT(0);
/* Set 1 after self-test / good reads; cleared after consecutive I2C failures. */
static atomic_t imu_healthy_atomic   = ATOMIC_INIT(0);
#define IMU_FAIL_STREAK_UNHEALTHY   20  /* ~200 ms at 100 Hz */

static int watchdog_main_channel = -1;
static int watchdog_safety_channel = -1;
static uint8_t product_device_id[8];
static K_MUTEX_DEFINE(heater_hw_mutex);
static K_MUTEX_DEFINE(adc_mutex);
static K_MUTEX_DEFINE(pmic_mutex);

static void watchdog_feed_main(void);

/* ================= SPI =================
 *
 * CS is SOFTWARE-ONLY (P1.12). Overlay must not declare cs-gpios on spi3
 * or the Zephyr SPIM driver will pulse CS on every spi_write() and break
 * multi-row GRAM fills → solid white screen on ST7735.
 *
 * Mode 0 (CPOL=0,CPHA=0), MSB first, 8 MHz — reliable on short PCB runs.
 * 16 MHz was flaky on some assemblies and looked like a white panel.
 */

static struct spi_config spi_cfg = {
    .frequency = 8000000,
    .operation = SPI_OP_MODE_MASTER | SPI_WORD_SET(8) | SPI_TRANSFER_MSB,
};

static inline int spi_fast(uint8_t b)
{
    struct spi_buf buf = { .buf = &b, .len = 1 };
    struct spi_buf_set tx = { .buffers = &buf, .count = 1 };
    return spi_write(spi_dev, &spi_cfg, &tx);
}

static inline int spi_bulk(const uint8_t *data, size_t len)
{
    struct spi_buf buf = { .buf = (void *)data, .len = len };
    struct spi_buf_set tx = { .buffers = &buf, .count = 1 };
    return spi_write(spi_dev, &spi_cfg, &tx);
}

/* ================= TFT LOW-LEVEL ================= */

static void tft_cmd(uint8_t c)
{
    gpio_pin_set(gpio1, TFT_DC_PIN, 0);
    gpio_pin_set(gpio1, TFT_CS_PIN, 0);
    (void)spi_fast(c);
    gpio_pin_set(gpio1, TFT_CS_PIN, 1);
}

static void tft_data(uint8_t d)
{
    gpio_pin_set(gpio1, TFT_DC_PIN, 1);
    gpio_pin_set(gpio1, TFT_CS_PIN, 0);
    (void)spi_fast(d);
    gpio_pin_set(gpio1, TFT_CS_PIN, 1);
}

static void tft_data_n(const uint8_t *d, size_t n)
{
    if (n == 0U) {
        return;
    }
    gpio_pin_set(gpio1, TFT_DC_PIN, 1);
    gpio_pin_set(gpio1, TFT_CS_PIN, 0);
    (void)spi_bulk(d, n);
    gpio_pin_set(gpio1, TFT_CS_PIN, 1);
}

static void tft_set_addr(int x, int y, int w, int h)
{
    uint16_t x0 = (uint16_t)(x + TFT_X_OFFSET);
    uint16_t y0 = (uint16_t)(y + TFT_Y_OFFSET);
    uint16_t x1 = (uint16_t)(x0 + w - 1);
    uint16_t y1 = (uint16_t)(y0 + h - 1);
    uint8_t caset[4] = {
        (uint8_t)(x0 >> 8), (uint8_t)x0,
        (uint8_t)(x1 >> 8), (uint8_t)x1,
    };
    uint8_t raset[4] = {
        (uint8_t)(y0 >> 8), (uint8_t)y0,
        (uint8_t)(y1 >> 8), (uint8_t)y1,
    };

    tft_cmd(0x2A);
    tft_data_n(caset, sizeof(caset));
    tft_cmd(0x2B);
    tft_data_n(raset, sizeof(raset));
    tft_cmd(0x2C);
}

static void fill_color(uint16_t color)
{
    uint8_t hi = (uint8_t)(color >> 8);
    uint8_t lo = (uint8_t)color;

    /* Full controller GRAM, independent of visible window offsets. */
    tft_set_addr(-TFT_X_OFFSET, -TFT_Y_OFFSET, TFT_GRAM_W, TFT_GRAM_H);

    static uint8_t row[TFT_GRAM_W * 2];
    for (int i = 0; i < TFT_GRAM_W; i++) {
        row[i * 2]     = hi;
        row[i * 2 + 1] = lo;
    }

    /*
     * Hold CS LOW for the entire frame. Releasing CS mid-frame ends the
     * RAMWR command on ST7735 and leaves the panel white / garbage.
     */
    gpio_pin_set(gpio1, TFT_DC_PIN, 1);
    gpio_pin_set(gpio1, TFT_CS_PIN, 0);
    for (int y = 0; y < TFT_GRAM_H; y++) {
        if (spi_bulk(row, sizeof(row)) != 0) {
            /* One retry on a flaky bit; keep CS held. */
            (void)spi_bulk(row, sizeof(row));
        }
        if ((y & 0x1F) == 0) {
            watchdog_feed_main();
        }
    }
    gpio_pin_set(gpio1, TFT_CS_PIN, 1);
}

/* Fill an arbitrary rectangle. Width is clamped to the row buffer AND
 * the SPI write length (v1 clamped only the buffer fill but pushed
 * w*2 bytes — latent buffer over-read for w > GRAM width). */
static void fill_rect(int x, int y, int w, int h, uint16_t color)
{
    if (w <= 0 || h <= 0) {
        return;
    }
    if (w > TFT_GRAM_W) {
        w = TFT_GRAM_W;
    }

    uint8_t hi = (uint8_t)(color >> 8);
    uint8_t lo = (uint8_t)color;
    static uint8_t row[TFT_GRAM_W * 2];
    for (int i = 0; i < w; i++) {
        row[i * 2]     = hi;
        row[i * 2 + 1] = lo;
    }

    tft_set_addr(x, y, w, h);
    gpio_pin_set(gpio1, TFT_DC_PIN, 1);
    gpio_pin_set(gpio1, TFT_CS_PIN, 0);
    for (int yy = 0; yy < h; yy++) {
        (void)spi_bulk(row, (size_t)w * 2U);
    }
    gpio_pin_set(gpio1, TFT_CS_PIN, 1);
}

/* ================= TFT POWER =================
 *
 * Panel: ST7735S 160x80 (0.96") on SPI3.
 * Minimal SLPOUT/MADCTL/COLMOD/DISPON is not enough on every glass —
 * without power/gamma the panel often sits pure white after 0x29.
 */

static void tft_init(void)
{
    /* Hardware reset */
    gpio_pin_set(gpio1, TFT_RST_PIN, 0);
    k_msleep(40);
    gpio_pin_set(gpio1, TFT_RST_PIN, 1);
    k_msleep(120);

    tft_cmd(0x01); /* SWRESET */
    k_msleep(150);

    tft_cmd(0x11); /* SLPOUT */
    k_msleep(120);

    /* Frame rate */
    {
        static const uint8_t b1[] = { 0x01, 0x2C, 0x2D };
        static const uint8_t b2[] = { 0x01, 0x2C, 0x2D };
        static const uint8_t b3[] = { 0x01, 0x2C, 0x2D, 0x01, 0x2C, 0x2D };
        tft_cmd(0xB1); tft_data_n(b1, sizeof(b1));
        tft_cmd(0xB2); tft_data_n(b2, sizeof(b2));
        tft_cmd(0xB3); tft_data_n(b3, sizeof(b3));
    }

    tft_cmd(0xB4); tft_data(0x07); /* INVCTR: no inversion */

    /* Power control */
    {
        static const uint8_t c0[] = { 0xA2, 0x02, 0x84 };
        static const uint8_t c2[] = { 0x0A, 0x00 };
        static const uint8_t c3[] = { 0x8A, 0x2A };
        static const uint8_t c4[] = { 0x8A, 0xEE };
        tft_cmd(0xC0); tft_data_n(c0, sizeof(c0));
        tft_cmd(0xC1); tft_data(0xC5);
        tft_cmd(0xC2); tft_data_n(c2, sizeof(c2));
        tft_cmd(0xC3); tft_data_n(c3, sizeof(c3));
        tft_cmd(0xC4); tft_data_n(c4, sizeof(c4));
        tft_cmd(0xC5); tft_data(0x0E); /* VCOM */
    }

    /* Runtime (see panel_invert), so ONE binary drives both glass variants. */
    tft_cmd(panel_invert ? 0x21 : 0x20);   /* INVON : INVOFF */

    /*
     * MADCTL 0xA0 = MY | MV, bit3 (RGB/BGR) CLEAR = RGB panel order.
     * COLMOD 0x05: 16-bit/pixel.
     *
     * WAS 0xA8 (bit3 set = BGR), which swapped the red and blue channels on
     * this glass. Verified on hardware 2026-09-07: the low-battery warning
     * COLOR_RED 0xF800 rendered as pure blue 0x001F. Green and white/black
     * are unaffected by an R<->B swap, which is exactly why the BLE/charging
     * green, the white text and the dark background all looked correct while
     * only red was wrong — and why this was mistaken for a panel-inversion
     * problem at first (inversion would have made red CYAN 0x07FF, not blue).
     */
    tft_cmd(0x36); tft_data(0xA0);
    tft_cmd(0x3A); tft_data(0x05);

    /* Column / row address windows (full GRAM) */
    {
        static const uint8_t ca[] = { 0x00, 0x00, 0x00, 0xA1 }; /* 0..161 */
        static const uint8_t ra[] = { 0x00, 0x00, 0x00, 0x83 }; /* 0..131 */
        tft_cmd(0x2A); tft_data_n(ca, sizeof(ca));
        tft_cmd(0x2B); tft_data_n(ra, sizeof(ra));
    }

    /* Gamma */
    {
        static const uint8_t g0[] = {
            0x0F, 0x1A, 0x0F, 0x18, 0x2F, 0x28, 0x20, 0x22,
            0x1F, 0x1B, 0x23, 0x37, 0x00, 0x07, 0x02, 0x10,
        };
        static const uint8_t g1[] = {
            0x0F, 0x1B, 0x0F, 0x17, 0x33, 0x2C, 0x29, 0x2E,
            0x30, 0x30, 0x39, 0x3F, 0x00, 0x07, 0x03, 0x10,
        };
        tft_cmd(0xE0); tft_data_n(g0, sizeof(g0));
        tft_cmd(0xE1); tft_data_n(g1, sizeof(g1));
    }

    tft_cmd(0x13); /* NORON */
    k_msleep(10);

    /*
     * Clear GRAM while the panel is still OFF, then DISPON.
     * Display-on before a full clear re-shows garbage / solid white.
     */
    fill_color(COLOR_BG);
    tft_cmd(0x29); /* DISPON */
    k_msleep(20);
}

static void tft_sleep(void)
{
    tft_cmd(0x28);
    tft_cmd(0x10);
    k_msleep(120);
}

/* ================= FONT (5x7) ================= */

static const uint8_t font_T[5]     = {0x01,0x01,0x7F,0x01,0x01};
static const uint8_t font_E[5]     = {0x7F,0x49,0x49,0x49,0x41};
static const uint8_t font_M[5]     = {0x7F,0x02,0x04,0x02,0x7F};
static const uint8_t font_P[5]     = {0x7F,0x09,0x09,0x09,0x06};
static const uint8_t font_C[5]     = {0x3E,0x41,0x41,0x41,0x22};
static const uint8_t font_I[5]     = {0x41,0x41,0x7F,0x41,0x41};
static const uint8_t font_S[5]     = {0x46,0x49,0x49,0x49,0x31};
static const uint8_t font_O[5]     = {0x3E,0x41,0x41,0x41,0x3E};
static const uint8_t font_N[5]     = {0x7F,0x02,0x0C,0x10,0x7F};
static const uint8_t font_A[5]     = {0x7E,0x11,0x11,0x11,0x7E};
static const uint8_t font_B[5]     = {0x7F,0x49,0x49,0x49,0x36};
static const uint8_t font_D[5]     = {0x7F,0x41,0x41,0x22,0x1C};
static const uint8_t font_F[5]     = {0x7F,0x09,0x09,0x09,0x01};
static const uint8_t font_G[5]     = {0x3E,0x41,0x49,0x49,0x7A};
static const uint8_t font_H[5]     = {0x7F,0x08,0x08,0x08,0x7F};
static const uint8_t font_L[5]     = {0x7F,0x40,0x40,0x40,0x40};
static const uint8_t font_R[5]     = {0x7F,0x09,0x19,0x29,0x46};
static const uint8_t font_U[5]     = {0x3F,0x40,0x40,0x40,0x3F};
static const uint8_t font_V[5]     = {0x1F,0x20,0x40,0x20,0x1F};
static const uint8_t font_X[5]     = {0x63,0x14,0x08,0x14,0x63};
static const uint8_t font_Y[5]     = {0x07,0x08,0x70,0x08,0x07};
static const uint8_t font_colon[5] = {0x00,0x36,0x36,0x00,0x00};
static const uint8_t font_deg[5]   = {0x06,0x09,0x09,0x06,0x00};
static const uint8_t font_space[5] = {0x00,0x00,0x00,0x00,0x00};
static const uint8_t font_minus[5] = {0x08,0x08,0x08,0x08,0x08};
static const uint8_t font_pct[5]   = {0x23,0x13,0x08,0x64,0x62};
static const uint8_t font_zap[5]   = {0x08,0x2C,0x1B,0x09,0x00};
static const uint8_t font_0[5] = {0x3E,0x51,0x49,0x45,0x3E};
static const uint8_t font_1[5] = {0x00,0x42,0x7F,0x40,0x00};
static const uint8_t font_2[5] = {0x62,0x51,0x49,0x49,0x46};
static const uint8_t font_3[5] = {0x22,0x49,0x49,0x49,0x36};
static const uint8_t font_4[5] = {0x18,0x14,0x12,0x7F,0x10};
static const uint8_t font_5[5] = {0x2F,0x49,0x49,0x49,0x31};
static const uint8_t font_6[5] = {0x3E,0x49,0x49,0x49,0x30};
static const uint8_t font_7[5] = {0x01,0x71,0x09,0x05,0x03};
static const uint8_t font_8[5] = {0x36,0x49,0x49,0x49,0x36};
static const uint8_t font_9[5] = {0x06,0x49,0x49,0x49,0x3E};

static const uint8_t *get_char(char c)
{
    switch (c) {
        case 'T': return font_T;  case 'E': return font_E;
        case 'M': return font_M;  case 'P': return font_P;
        case 'C': return font_C;  case 'I': return font_I;
        case 'S': return font_S;  case 'O': return font_O;
        case 'N': return font_N;  case 'o': return font_deg;
        case 'A': return font_A;  case 'B': return font_B;
        case 'D': return font_D;  case 'F': return font_F;
        case 'G': return font_G;  case 'H': return font_H;
        case 'L': return font_L;  case 'R': return font_R;
        case 'U': return font_U;  case 'V': return font_V;
        case 'X': return font_X;  case 'Y': return font_Y;
        case ':': return font_colon;
        case ' ': return font_space; case '-': return font_minus;
        case '%': return font_pct;
        case '~': return font_zap;
        case '0': return font_0;  case '1': return font_1;
        case '2': return font_2;  case '3': return font_3;
        case '4': return font_4;  case '5': return font_5;
        case '6': return font_6;  case '7': return font_7;
        case '8': return font_8;  case '9': return font_9;
        default:  return font_space;
    }
}

#define GLYPH_W      5
#define GLYPH_H      7

/* ----- Big-text drawing ----- */
#define BIG_CELL_W   (6 * SCALE)
#define BIG_CELL_H   (7 * SCALE)
#define BIG_CELL_BYTES (BIG_CELL_W * BIG_CELL_H * 2)

static void draw_char_big(int x, int y, char c, uint16_t fg, uint16_t bg)
{
    const uint8_t *g = get_char(c);
    uint8_t fg_hi = fg >> 8, fg_lo = fg & 0xFF;
    uint8_t bg_hi = bg >> 8, bg_lo = bg & 0xFF;

    static uint8_t cell[BIG_CELL_BYTES];
    int idx = 0;

    for (int py = 0; py < BIG_CELL_H; py++) {
        int gy = py / SCALE;
        for (int px = 0; px < BIG_CELL_W; px++) {
            int gx = px / SCALE;
            int on = 0;
            if (gx < GLYPH_W && gy < GLYPH_H) {
                on = (g[gx] >> gy) & 1;
            }
            if (on) { cell[idx++] = fg_hi; cell[idx++] = fg_lo; }
            else    { cell[idx++] = bg_hi; cell[idx++] = bg_lo; }
        }
    }

    tft_set_addr(x, y, BIG_CELL_W, BIG_CELL_H);
    gpio_pin_set(gpio1, TFT_DC_PIN, 1);
    gpio_pin_set(gpio1, TFT_CS_PIN, 0);
    spi_bulk(cell, BIG_CELL_BYTES);
    gpio_pin_set(gpio1, TFT_CS_PIN, 1);
}

static void draw_text_big_at(int x, int y, const char *s, uint16_t fg, uint16_t bg)
{
    for (int i = 0; s[i]; i++) {
        draw_char_big(x + i * BIG_CELL_W, y, s[i], fg, bg);
    }
}

static void draw_text_big_center(const char *s, int y, uint16_t fg, uint16_t bg)
{
    int len = strlen(s);
    int x = (TFT_VISIBLE_W - (len * BIG_CELL_W)) / 2;
    if (x < UI_SAFE_X0) {
        x = UI_SAFE_X0;
    }
    draw_text_big_at(x, y, s, fg, bg);
}

/* ----- Small-text drawing (status bar / debug view) ----- */
#define SMALL_CELL_W   6
#define SMALL_CELL_H   8
#define SMALL_CELL_BYTES (SMALL_CELL_W * SMALL_CELL_H * 2)

static void draw_char_small(int x, int y, char c, uint16_t fg, uint16_t bg)
{
    const uint8_t *g = get_char(c);
    uint8_t fg_hi = fg >> 8, fg_lo = fg & 0xFF;
    uint8_t bg_hi = bg >> 8, bg_lo = bg & 0xFF;

    static uint8_t cell[SMALL_CELL_BYTES];
    int idx = 0;

    for (int py = 0; py < SMALL_CELL_H; py++) {
        for (int px = 0; px < SMALL_CELL_W; px++) {
            int on = 0;
            if (px < GLYPH_W && py < GLYPH_H) {
                on = (g[px] >> py) & 1;
            }
            if (on) { cell[idx++] = fg_hi; cell[idx++] = fg_lo; }
            else    { cell[idx++] = bg_hi; cell[idx++] = bg_lo; }
        }
    }

    tft_set_addr(x, y, SMALL_CELL_W, SMALL_CELL_H);
    gpio_pin_set(gpio1, TFT_DC_PIN, 1);
    gpio_pin_set(gpio1, TFT_CS_PIN, 0);
    spi_bulk(cell, SMALL_CELL_BYTES);
    gpio_pin_set(gpio1, TFT_CS_PIN, 1);
}

static void draw_text_small_at(int x, int y, const char *s, uint16_t fg, uint16_t bg)
{
    for (int i = 0; s[i]; i++) {
        draw_char_small(x + i * SMALL_CELL_W, y, s[i], fg, bg);
    }
}

/* ================= BLUETOOTH ICON ================= */
/*
 * Official Bluetooth rune (vertical staff + two triangles) plus two
 * radio-wave arcs on the right — the same mark as the product BT artwork,
 * not the letters "BT". 15×15 fits the status strip inside the R4 window.
 */

#define BT_ICON_W 15
#define BT_ICON_H 15

static const uint8_t bt_bitmap[BT_ICON_H][BT_ICON_W] = {
    {0,0,0,1,1,0,0,0,0,0,0,0,0,0,0},
    {0,0,0,1,1,1,0,0,0,0,0,0,0,0,0},
    {0,0,0,1,1,1,1,0,0,0,0,0,1,0,1},
    {0,0,0,1,1,0,1,1,0,0,0,1,0,1,0},
    {1,1,0,1,1,0,0,1,1,0,1,0,0,1,0},
    {0,1,1,1,1,0,1,1,0,0,1,0,0,0,1},
    {0,0,1,1,1,1,1,0,0,0,0,1,0,1,0},
    {0,0,0,1,1,1,0,0,0,0,0,0,1,0,0},
    {0,0,1,1,1,1,1,0,0,0,0,1,0,1,0},
    {0,1,1,1,1,0,1,1,0,0,1,0,0,0,1},
    {1,1,0,1,1,0,0,1,1,0,1,0,0,1,0},
    {0,0,0,1,1,0,1,1,0,0,0,1,0,1,0},
    {0,0,0,1,1,1,1,0,0,0,0,0,1,0,1},
    {0,0,0,1,1,1,0,0,0,0,0,0,0,0,0},
    {0,0,0,1,1,0,0,0,0,0,0,0,0,0,0},
};

static void draw_bt_icon(int x, int y, uint16_t color)
{
    static uint8_t cell[BT_ICON_W * BT_ICON_H * 2];
    uint8_t fg_hi = color >> 8, fg_lo = color & 0xFF;
    uint8_t bg_hi = COLOR_BG >> 8, bg_lo = COLOR_BG & 0xFF;

    int idx = 0;
    for (int row = 0; row < BT_ICON_H; row++) {
        for (int col = 0; col < BT_ICON_W; col++) {
            if (bt_bitmap[row][col]) {
                cell[idx++] = fg_hi; cell[idx++] = fg_lo;
            } else {
                cell[idx++] = bg_hi; cell[idx++] = bg_lo;
            }
        }
    }
    tft_set_addr(x, y, BT_ICON_W, BT_ICON_H);
    gpio_pin_set(gpio1, TFT_DC_PIN, 1);
    gpio_pin_set(gpio1, TFT_CS_PIN, 0);
    spi_bulk(cell, sizeof(cell));
    gpio_pin_set(gpio1, TFT_CS_PIN, 1);
}

/* ================= HEATER ICON ================= */

#define HEATER_ICON_W 9
#define HEATER_ICON_H 15

static const uint8_t heater_bitmap[HEATER_ICON_H][HEATER_ICON_W] = {
    {0,0,1,1,0,0,0,1,1}, {0,1,1,0,0,1,1,0,0}, {1,1,0,0,1,1,0,0,0},
    {1,1,0,0,1,1,0,0,1}, {0,1,1,0,0,1,1,0,1}, {0,0,1,1,0,0,1,1,1},
    {0,0,1,1,0,0,0,1,1}, {0,1,1,0,0,1,1,0,0}, {1,1,0,0,1,1,0,0,0},
    {1,1,0,0,1,1,0,0,1}, {0,1,1,0,0,1,1,0,1}, {0,0,1,1,0,0,1,1,1},
    {0,0,0,1,1,0,0,0,0}, {0,0,0,0,1,1,0,0,0}, {0,0,0,0,0,1,1,0,0},
};

static void draw_heater_icon(int x, int y)
{
    static uint8_t cell[HEATER_ICON_W * HEATER_ICON_H * 2];
    uint8_t fh = COLOR_RED >> 8, fl = COLOR_RED & 0xFF;
    uint8_t bh = COLOR_BG >> 8, bl = COLOR_BG & 0xFF;
    int idx = 0;

    for (int r = 0; r < HEATER_ICON_H; r++) {
        for (int c = 0; c < HEATER_ICON_W; c++) {
            if (heater_bitmap[r][c]) {
                cell[idx++] = fh; cell[idx++] = fl;
            } else {
                cell[idx++] = bh; cell[idx++] = bl;
            }
        }
    }
    tft_set_addr(x, y, HEATER_ICON_W, HEATER_ICON_H);
    gpio_pin_set(gpio1, TFT_DC_PIN, 1);
    gpio_pin_set(gpio1, TFT_CS_PIN, 0);
    spi_bulk(cell, sizeof(cell));
    gpio_pin_set(gpio1, TFT_CS_PIN, 1);
}

/* ================= BATTERY ICON ================= */

#define BAT_ICON_W       28
#define BAT_ICON_H       14
#define BAT_BODY_W       24
#define BAT_FILL_X0      2
#define BAT_FILL_X1      21
#define BAT_FILL_Y0      2
#define BAT_FILL_Y1      11
#define BAT_FILL_W       (BAT_FILL_X1 - BAT_FILL_X0 + 1)
#define BAT_CAP_TOP      4
#define BAT_CAP_BOT      9
#define BAT_CAP_X1       (BAT_BODY_W + 4 - 1)

#define BAT_BUF_BYTES    (BAT_ICON_W * BAT_ICON_H * 2)

static int bat_fill_pixels(uint8_t pct)
{
    if (pct >= 100) return BAT_FILL_W;
    if (pct == 0)   return 0;
    int px = (BAT_FILL_W * (int)pct + 50) / 100;
    if (px < 1) px = 1;
    if (px > BAT_FILL_W) px = BAT_FILL_W;
    return px;
}

static void draw_battery_icon(int x, int y, uint8_t pct, uint16_t color)
{
    static uint8_t cell[BAT_BUF_BYTES];
    uint8_t fg_hi = color >> 8, fg_lo = color & 0xFF;
    uint8_t bg_hi = COLOR_BG >> 8, bg_lo = COLOR_BG & 0xFF;

    int fill_px = bat_fill_pixels(pct);
    int fill_x_end = BAT_FILL_X0 + fill_px;

    int idx = 0;
    for (int row = 0; row < BAT_ICON_H; row++) {
        for (int col = 0; col < BAT_ICON_W; col++) {
            bool on = false;

            if (col < BAT_BODY_W) {
                if (row == 0 || row == BAT_ICON_H - 1) {
                    on = true;
                } else if (col == 0) {
                    on = true;
                } else if (col == BAT_BODY_W - 1) {
                    on = (row < BAT_CAP_TOP || row > BAT_CAP_BOT);
                } else if (col >= BAT_FILL_X0 && col < fill_x_end &&
                           row >= BAT_FILL_Y0 && row <= BAT_FILL_Y1) {
                    on = true;
                }
            } else if (row >= BAT_CAP_TOP && row <= BAT_CAP_BOT) {
                if (row == BAT_CAP_TOP || row == BAT_CAP_BOT) {
                    on = true;
                } else if (col == BAT_CAP_X1) {
                    on = true;
                }
            }

            if (on) { cell[idx++] = fg_hi; cell[idx++] = fg_lo; }
            else    { cell[idx++] = bg_hi; cell[idx++] = bg_lo; }
        }
    }

    tft_set_addr(x, y, BAT_ICON_W, BAT_ICON_H);
    gpio_pin_set(gpio1, TFT_DC_PIN, 1);
    gpio_pin_set(gpio1, TFT_CS_PIN, 0);
    spi_bulk(cell, BAT_BUF_BYTES);
    gpio_pin_set(gpio1, TFT_CS_PIN, 1);
}

/* ================= LIGHTNING BOLT ================= */

#define BOLT_W 6
#define BOLT_H 14

static const uint8_t bolt_bitmap[BOLT_H][BOLT_W] = {
    {0,0,0,1,1,0},
    {0,0,1,1,0,0},
    {0,0,1,1,0,0},
    {0,1,1,0,0,0},
    {0,1,1,0,0,0},
    {1,1,1,1,1,1},
    {0,0,1,1,0,0},
    {0,1,1,0,0,0},
    {0,1,1,0,0,0},
    {1,1,0,0,0,0},
    {1,1,0,0,0,0},
    {0,1,1,0,0,0},
    {1,1,0,0,0,0},
    {1,1,0,0,0,0},
};

static void draw_bolt_icon(int x, int y, uint16_t color)
{
    static uint8_t cell[BOLT_W * BOLT_H * 2];
    uint8_t fg_hi = color >> 8, fg_lo = color & 0xFF;
    uint8_t bg_hi = COLOR_BG >> 8, bg_lo = COLOR_BG & 0xFF;

    int idx = 0;
    for (int row = 0; row < BOLT_H; row++) {
        for (int col = 0; col < BOLT_W; col++) {
            if (bolt_bitmap[row][col]) {
                cell[idx++] = fg_hi; cell[idx++] = fg_lo;
            } else {
                cell[idx++] = bg_hi; cell[idx++] = bg_lo;
            }
        }
    }

    tft_set_addr(x, y, BOLT_W, BOLT_H);
    gpio_pin_set(gpio1, TFT_DC_PIN, 1);
    gpio_pin_set(gpio1, TFT_CS_PIN, 0);
    spi_bulk(cell, sizeof(cell));
    gpio_pin_set(gpio1, TFT_CS_PIN, 1);
}

/* ================= TEMP WARN (display/log only — no buzzer) ================= */

#define TEMP_WARN_HIGH_C        55
#define TEMP_WARN_REARM_C       50
/* Require N consecutive hot readings before alarming — filters ADC
 * spikes when the physical heater is ramping (avoids false 55 C trip). */
#define TEMP_WARN_DEBOUNCE      3

/* ================= NTC ================= */

#define R_FIXED 10000.0f
#define R0      10000.0f
#define BETA    3435.0f
#define T0      298.15f
/* Divider: V_SUPPLY --[NTC]--+--AIN0(P0.02)--[10k]--GND
 * Formula r = R_FIXED*(V_SUPPLY/v - 1) matches this NTC-top
 * topology. PCB NTC rail is 3.0 V (was 3.3 / 2.8 in older builds). */
#define V_SUPPLY 3.0f

__unused static float ntc_temp(float v)
{
    if (v < 0.001f) v = 0.001f;
    float r   = R_FIXED * ((V_SUPPLY / v) - 1);
    if (r < 1.0f) r = 1.0f;
    float inv = (1.0f / T0) + (1.0f / BETA) * logf(r / R0);
    return (1.0f / inv) - 273.15f;
}

/* Same Beta math with an explicit supply — used by the RTT diagnostic
 * to print the ORIGINAL firmware's result next to the current one. */
__unused static float ntc_temp_with(float supply, float v)
{
    if (v < 0.001f) v = 0.001f;
    float r   = R_FIXED * ((supply / v) - 1);
    if (r < 1.0f) r = 1.0f;
    float inv = (1.0f / T0) + (1.0f / BETA) * logf(r / R0);
    return (1.0f / inv) - 273.15f;
}

static float ntc_temp_from_raw(float raw)
{
#if NTC_MATH_V1
    float v = raw * 2.8f / 4095.0f;
    return ntc_temp_with(2.8f, v);
#else
    float v = raw * ADC_FULL_SCALE_V / 4095.0f;
    return ntc_temp(v);
#endif
}

/* ================= ADC FILTER ================= */

static int32_t adc_window[FILTER_LEN];
static int     adc_window_idx;
static int     adc_window_count;
static int32_t adc_window_sum;

static void adc_filter_reset(void)
{
    memset(adc_window, 0, sizeof(adc_window));
    adc_window_idx = 0;
    adc_window_count = 0;
    adc_window_sum = 0;
}

static float adc_filter_push(int32_t s)
{
    if (adc_window_count < FILTER_LEN) {
        adc_window[adc_window_idx] = s;
        adc_window_sum += s;
        adc_window_idx = (adc_window_idx + 1) % FILTER_LEN;
        adc_window_count++;
        return (float)adc_window_sum / (float)adc_window_count;
    }
    adc_window_sum -= adc_window[adc_window_idx];
    adc_window[adc_window_idx] = s;
    adc_window_sum += s;
    adc_window_idx = (adc_window_idx + 1) % FILTER_LEN;
    return (float)adc_window_sum / (float)FILTER_LEN;
}

static int hysteresis_round(float temp_c, int last_int)
{
    if (last_int == INT_MIN) return (int)lroundf(temp_c);
    float delta = temp_c - (float)last_int;
    if (delta >=  (0.5f + HYSTERESIS_C))  return last_int + 1;
    if (delta <= -(0.5f + HYSTERESIS_C))  return last_int - 1;
    return last_int;
}

/* ================= BMI270 DRIVER (Zephyr sensor API) ================= */

/* BLE wire format for one IMU sample (little-endian int16s).
 * Gyro uses 0.1 dps/LSB so ±2000 dps sensor FS fits int16 (±3276.7).
 * (0.01 dps/LSB only covered ±327 dps and clipped wrist twists.) */
typedef struct __attribute__((packed)) {
    int16_t ax, ay, az;     /* milli-g     */
    int16_t gx, gy, gz;     /* 0.1 deg/s   */
} imu_sample_t;
BUILD_ASSERT(sizeof(imu_sample_t) == 12, "imu_sample_t must be 12 bytes");

struct imu_eng {
    float ax_g, ay_g, az_g;       /* g */
    float gx_dps, gy_dps, gz_dps; /* deg/s */
};

static inline int16_t f_to_i16(float v)
{
    if (v >  32767.0f) {
        return 32767;
    }
    if (v < -32768.0f) {
        return -32768;
    }
    return (int16_t)lroundf(v);
}

static int bmi270_init(void)
{
    if (!device_is_ready(imu_dev)) {
        LOG_ERR("BMI270 device not ready (check overlay bosch,bmi270 @0x68)");
        return -ENODEV;
    }

    struct sensor_value fs, sf, os;
    int ret;

    fs.val1 = IMU_ACC_RANGE_G;
    fs.val2 = 0;
    os.val1 = 1;
    os.val2 = 0;
    sf.val1 = IMU_ODR_HZ;
    sf.val2 = 0;

    ret = sensor_attr_set(imu_dev, SENSOR_CHAN_ACCEL_XYZ,
                          SENSOR_ATTR_FULL_SCALE, &fs);
    if (ret) {
        LOG_ERR("BMI270 acc range: %d", ret);
        return ret;
    }
    ret = sensor_attr_set(imu_dev, SENSOR_CHAN_ACCEL_XYZ,
                          SENSOR_ATTR_OVERSAMPLING, &os);
    if (ret) {
        LOG_ERR("BMI270 acc osr: %d", ret);
        return ret;
    }
    ret = sensor_attr_set(imu_dev, SENSOR_CHAN_ACCEL_XYZ,
                          SENSOR_ATTR_SAMPLING_FREQUENCY, &sf);
    if (ret) {
        LOG_ERR("BMI270 acc odr: %d", ret);
        return ret;
    }

    fs.val1 = IMU_GYR_RANGE_DPS;
    ret = sensor_attr_set(imu_dev, SENSOR_CHAN_GYRO_XYZ,
                          SENSOR_ATTR_FULL_SCALE, &fs);
    if (ret) {
        LOG_ERR("BMI270 gyr range: %d", ret);
        return ret;
    }
    ret = sensor_attr_set(imu_dev, SENSOR_CHAN_GYRO_XYZ,
                          SENSOR_ATTR_OVERSAMPLING, &os);
    if (ret) {
        LOG_ERR("BMI270 gyr osr: %d", ret);
        return ret;
    }
    ret = sensor_attr_set(imu_dev, SENSOR_CHAN_GYRO_XYZ,
                          SENSOR_ATTR_SAMPLING_FREQUENCY, &sf);
    if (ret) {
        LOG_ERR("BMI270 gyr odr: %d", ret);
        return ret;
    }

    k_msleep(50);
    LOG_INF("BMI270 ready: +/-%dg, +/-%ddps, %d Hz",
            IMU_ACC_RANGE_G, IMU_GYR_RANGE_DPS, IMU_ODR_HZ);
    return 0;
}

/*
 * Sole owner of BMI270 fetch/get must be imu_thread. sensor_sample_fetch
 * is stateful and is not safe across two threads.
 */
/* ---- BMI270 suspend (raw I2C) ----
 *
 * Clearing imu_thread_enabled only stops OUR sampling thread; the sensor keeps
 * converting. With accel+gyro at 100 Hz the BMI270 draws ~700 uA continuously
 * -- roughly 200x the nRF52840's System OFF current -- so a spoon that is
 * "off" still flattens the pack in days. CONFIG_PM_DEVICE is not enabled and
 * the Zephyr BMI270 driver exposes no suspend hook (its ODR setter only
 * accepts 50-1600 Hz), so write the Bosch power registers directly, the same
 * way this firmware already pokes the nPM and TPS registers.
 *
 * bmi270_init() fully reconfigures the sensor on the next wake, so nothing
 * needs to undo this. */
#define BMI270_I2C_ADDR      0x68
#define BMI270_REG_PWR_CONF  0x7C
#define BMI270_REG_PWR_CTRL  0x7D

static void bmi270_suspend(void)
{
    if (i2c_dev == NULL) {
        return;
    }
    /* Sensing blocks off first (acc/gyr/aux/temp), then advanced power save. */
    int ret = i2c_reg_write_byte(i2c_dev, BMI270_I2C_ADDR,
                                 BMI270_REG_PWR_CTRL, 0x00);
    if (ret == 0) {
        ret = i2c_reg_write_byte(i2c_dev, BMI270_I2C_ADDR,
                                 BMI270_REG_PWR_CONF, 0x03);
    }
    if (ret != 0) {
        LOG_WRN("BMI270 suspend failed (%d) - sleep current stays high", ret);
    } else {
        LOG_INF("BMI270 suspended (~3.5 uA)");
    }
}

static int bmi270_read(struct imu_eng *out)
{
    struct sensor_value a[3], g[3];
    int ret = sensor_sample_fetch(imu_dev);

    if (ret < 0) {
        return ret;
    }
    ret = sensor_channel_get(imu_dev, SENSOR_CHAN_ACCEL_XYZ, a);
    if (ret < 0) {
        return ret;
    }
    ret = sensor_channel_get(imu_dev, SENSOR_CHAN_GYRO_XYZ, g);
    if (ret < 0) {
        return ret;
    }

    /* sensor API: accel m/s^2, gyro rad/s */
    const float MS2_PER_G = 9.80665f;
    const float DEG_PER_RAD = 57.29577951308232f;

    out->ax_g = (float)sensor_value_to_double(&a[0]) / MS2_PER_G;
    out->ay_g = (float)sensor_value_to_double(&a[1]) / MS2_PER_G;
    out->az_g = (float)sensor_value_to_double(&a[2]) / MS2_PER_G;
    out->gx_dps = (float)sensor_value_to_double(&g[0]) * DEG_PER_RAD;
    out->gy_dps = (float)sensor_value_to_double(&g[1]) * DEG_PER_RAD;
    out->gz_dps = (float)sensor_value_to_double(&g[2]) * DEG_PER_RAD;
    return 0;
}

/* Pack one sample into BLE units: milli-g + 0.1 deg/s. */
static void imu_eng_to_pkt(const struct imu_eng *s, imu_sample_t *pkt)
{
    pkt->ax = f_to_i16(s->ax_g * 1000.0f);
    pkt->ay = f_to_i16(s->ay_g * 1000.0f);
    pkt->az = f_to_i16(s->az_g * 1000.0f);
    pkt->gx = f_to_i16(s->gx_dps * 10.0f);
    pkt->gy = f_to_i16(s->gy_dps * 10.0f);
    pkt->gz = f_to_i16(s->gz_dps * 10.0f);
}

/*
 * Boot IMU health check. Failures leave imu_healthy_atomic = 0 so the
 * bite counter stays inactive until a later good sample.
 */
static int bmi270_selftest(void)
{
    int ok = 0;
    int err = 0;
    float sum_ax = 0.0f, sum_ay = 0.0f, sum_az = 0.0f;

    for (int i = 0; i < 10; i++) {
        struct imu_eng s;

        if (bmi270_read(&s) != 0) {
            err++;
            k_msleep(10);
            continue;
        }
        sum_ax += s.ax_g;
        sum_ay += s.ay_g;
        sum_az += s.az_g;
        atomic_set(&imu_last_ax_mg, (atomic_val_t)f_to_i16(s.ax_g * 1000.0f));
        atomic_set(&imu_last_ay_mg, (atomic_val_t)f_to_i16(s.ay_g * 1000.0f));
        atomic_set(&imu_last_az_mg, (atomic_val_t)f_to_i16(s.az_g * 1000.0f));
        ok++;
        k_msleep(10);
    }

    atomic_set(&imu_sample_ok_count, ok);
    atomic_set(&imu_sample_err_count, err);

    if (ok < 5) {
        LOG_ERR("IMU self-test: only %d/10 reads OK (%d errors)", ok, err);
        atomic_set(&imu_healthy_atomic, 0);
        return -EIO;
    }

    float ax = sum_ax / (float)ok;
    float ay = sum_ay / (float)ok;
    float az = sum_az / (float)ok;
    float mag = sqrtf(ax * ax + ay * ay + az * az);

    /* Stationary: |a| near 1 g. */
    if (mag < 0.5f || mag > 1.5f) {
        LOG_ERR("IMU self-test: implausible |a|=%.2f g (ax=%.2f ay=%.2f az=%.2f)",
                (double)mag, (double)ax, (double)ay, (double)az);
        atomic_set(&imu_healthy_atomic, 0);
        return -EINVAL;
    }

    atomic_set(&imu_healthy_atomic, 1);
    LOG_INF("IMU self-test OK: ax=%.2f ay=%.2f az=%.2f g (|a|=%.2f), %d/10",
            (double)ax, (double)ay, (double)az, (double)mag, ok);
    return 0;
}

/* ================= nPM1300 ================= */

static atomic_t npm_cached_vbus_status = ATOMIC_INIT(0);
static atomic_t npm_cached_charge_status = ATOMIC_INIT(0);
static atomic_t npm_cached_error = ATOMIC_INIT(0);
static atomic_t npm_cached_vbat_mv = ATOMIC_INIT(0);
/* Signed battery current in mA, nPM13xx convention: POSITIVE = charging into
 * the cell, NEGATIVE = discharging. Only meaningful once the charger node
 * declares the correct part (the nPM1304 scaling factors gave wrong values). */
static atomic_t npm_cached_ibat_ma = ATOMIC_INIT(0);

static int npm_init(void)
{
    if (!device_is_ready(charger_dev)) {
        LOG_ERR("nPM1300 charger driver is not ready");
        return -ENODEV;
    }

    int ret = sensor_sample_fetch(charger_dev);
    if (ret < 0) {
        LOG_ERR("nPM1300 initial sample failed (%d)", ret);
        return ret;
    }

    /* Matches boards/...overlay: VTERM 4.20 V, ICHG 500 mA, ITERM 10 %,
     * IDISCHG 1000 mA, VBUS ILIM 1000 mA, die-temp stop 80 C. */
    LOG_INF("nPM1300 ready: ICHG=500mA VTERM=4.20V ITERM=10%% IDISCHG=1000mA ILIM=1000mA");
    LOG_WRN("Battery NTC is absent on this PCB; add a cell NTC before production");
    return 0;
}

/* ---- Non-blocking VBAT measurement ----
 *
 * v1 blocked the main loop for 10 ms inside the measurement (k_msleep
 * between trigger and read), which added jitter to the 20 Hz bite
 * sampling every battery poll. Now the trigger and the read are two
 * separate calls driven by the main-loop state machine. */

static int npm_vbat_trigger(void)
{
    /* The upstream sensor driver triggers all ADC measurements atomically
     * inside sensor_sample_fetch(). Keep the two-phase caller interface so
     * the UI/battery state machine remains unchanged. */
    return 0;
}

static uint16_t npm_vbat_read_mv(void)
{
    struct sensor_value voltage;
    struct sensor_value status;
    struct sensor_value vbus;
    struct sensor_value error;

    k_mutex_lock(&pmic_mutex, K_FOREVER);
    int ret = sensor_sample_fetch(charger_dev);
    if (ret < 0 ||
        sensor_channel_get(charger_dev, SENSOR_CHAN_GAUGE_VOLTAGE, &voltage) < 0 ||
        sensor_channel_get(charger_dev, SENSOR_CHAN_NPM13XX_CHARGER_STATUS, &status) < 0 ||
        sensor_channel_get(charger_dev, SENSOR_CHAN_NPM13XX_CHARGER_VBUS_STATUS, &vbus) < 0 ||
        sensor_channel_get(charger_dev, SENSOR_CHAN_NPM13XX_CHARGER_ERROR, &error) < 0) {
        k_mutex_unlock(&pmic_mutex);
        atomic_set(&battery_status_valid, 0);
        LOG_WRN("nPM1300 sample/read failed (%d)", ret);
        return 0;
    }

    int64_t mv = (int64_t)voltage.val1 * 1000LL + voltage.val2 / 1000;
    if (mv <= 0 || mv > UINT16_MAX) {
        k_mutex_unlock(&pmic_mutex);
        atomic_set(&battery_status_valid, 0);
        return 0;
    }

    uint8_t previous_error = (uint8_t)atomic_get(&npm_cached_error);
    uint8_t current_error = (uint8_t)error.val1;
    atomic_set(&npm_cached_charge_status, (atomic_val_t)(uint8_t)status.val1);
    atomic_set(&npm_cached_vbus_status, (atomic_val_t)(uint8_t)vbus.val1);
    atomic_set(&npm_cached_error, (atomic_val_t)current_error);
    atomic_set(&npm_cached_vbat_mv, (atomic_val_t)mv);

    /* Battery current is optional: a failure here must not invalidate an
     * otherwise good voltage/status sample, so read it separately and fall
     * back to 0 mA (= no IR correction) rather than failing the whole poll. */
    struct sensor_value ibat;
    if (sensor_channel_get(charger_dev, SENSOR_CHAN_GAUGE_AVG_CURRENT, &ibat) == 0) {
        int32_t ima = ibat.val1 * 1000 + ibat.val2 / 1000;
        atomic_set(&npm_cached_ibat_ma, (atomic_val_t)ima);
    } else {
        atomic_set(&npm_cached_ibat_ma, 0);
    }

    atomic_set(&battery_status_valid, 1);
    k_mutex_unlock(&pmic_mutex);

    if (current_error != 0U && current_error != previous_error) {
        LOG_ERR("nPM1300 charger fault 0x%02X", current_error);
    }
    return (uint16_t)mv;
}

/* Loaded terminal voltage -> open-circuit estimate. Positive (charge) current
 * subtracts the IR rise; negative (discharge) current adds the IR sag back. */
static uint16_t npm_vbat_ocv_mv(uint16_t loaded_mv)
{
    int32_t ima = (int32_t)atomic_get(&npm_cached_ibat_ma);
    int32_t ocv = (int32_t)loaded_mv - (ima * BATT_IR_MOHM) / 1000;

    if (ocv < 0)           return 0;
    if (ocv > UINT16_MAX)  return UINT16_MAX;
    return (uint16_t)ocv;
}

static uint8_t npm_battery_percent(uint16_t mv)
{
    float v = mv / 1000.0f;
    float p;
    if      (v >= 4.20f) p = 100.0f;
    else if (v >= 4.00f) p = 80.0f + (v - 4.00f) * (20.0f / 0.20f);
    else if (v >= 3.85f) p = 60.0f + (v - 3.85f) * (20.0f / 0.15f);
    else if (v >= 3.70f) p = 40.0f + (v - 3.70f) * (20.0f / 0.15f);
    else if (v >= 3.60f) p = 20.0f + (v - 3.60f) * (20.0f / 0.10f);
    else if (v >= 3.50f) p = 10.0f + (v - 3.50f) * (10.0f / 0.10f);
    else if (v >= 3.30f) p =  0.0f + (v - 3.30f) * (10.0f / 0.20f);
    else                 p =  0.0f;
    if (p < 0)   p = 0;
    if (p > 100) p = 100;
    return (uint8_t)(p + 0.5f);
}

/* ================= TPS628682 ================= */

static int tps_drive_off_locked(void)
{
    int ret = gpio_pin_set(gpio0, TPS_EN_PIN, 0);

    if (ret == 0) {
        atomic_set(&tps_rail_state, 0);
    } else {
        /* Never claim the power rail is off when the GPIO driver could not
         * prove it. The caller reboots after dropping the mutex; EN is
         * configured low at the first instruction path of main(). */
        atomic_set(&heater_fault_atomic, 1);
        LOG_ERR("TPS: CRITICAL, EN could not be driven LOW (%d)", ret);
    }
    return ret;
}

static void tps_reset_after_off_failure(int error)
{
    LOG_ERR("TPS: unsafe rail-off state (%d), forcing cold reset", error);
    sys_reboot(SYS_REBOOT_COLD);
}

static int tps_init(void)
{
    /* EN low resets TPS628682 I2C registers. Do not pulse the heater at
     * boot; configure and verify VOUT on every OFF->ON transition. */
    int ret = gpio_pin_set(gpio0, TPS_EN_PIN, 0);
    if (ret < 0) {
        return ret;
    }
    atomic_set(&tps_rail_state, 0);
    LOG_INF("TPS628682: EN=LOW, rail OFF");
    return 0;
}

static int tps_rail_on(void)
{
    k_mutex_lock(&heater_hw_mutex, K_FOREVER);

    if (atomic_get(&tps_rail_state)) {
        k_mutex_unlock(&heater_hw_mutex);
        return 0;
    }

    int ret = gpio_pin_set(gpio0, TPS_EN_PIN, 1);
    if (ret < 0) {
        k_mutex_unlock(&heater_hw_mutex);
        return ret;
    }

    k_usleep(TPS_EN_SETTLE_US);

    uint8_t tx[2] = { TPS_REG_VOUT, TPS_VOUT_3V10 };
    uint8_t addr = TPS_ADDR;
    ret = i2c_write(i2c_dev, tx, sizeof(tx), addr);
    if (ret < 0) {
        addr = TPS_ADDR_ALT;
        ret = i2c_write(i2c_dev, tx, sizeof(tx), addr);
    }
    if (ret < 0) {
        int off_ret = tps_drive_off_locked();
        LOG_ERR("TPS: VOUT write failed (%d), rail forced OFF", ret);
        k_mutex_unlock(&heater_hw_mutex);
        if (off_ret < 0) {
            tps_reset_after_off_failure(off_ret);
        }
        return ret;
    }

    uint8_t readback = 0;
    ret = i2c_reg_read_byte(i2c_dev, addr, TPS_REG_VOUT, &readback);
    if (ret < 0 || readback != TPS_VOUT_3V10) {
        int off_ret = tps_drive_off_locked();
        LOG_ERR("TPS: VOUT verify failed (%d, 0x%02X), rail forced OFF",
                ret, readback);
        k_mutex_unlock(&heater_hw_mutex);
        if (off_ret < 0) {
            tps_reset_after_off_failure(off_ret);
        }
        return (ret < 0) ? ret : -EIO;
    }

    if (!atomic_get(&heater_on_atomic)) {
        int off_ret = tps_drive_off_locked();
        k_mutex_unlock(&heater_hw_mutex);
        if (off_ret < 0) {
            tps_reset_after_off_failure(off_ret);
        }
        return -ECANCELED;
    }

    tps_i2c_addr = addr;
    atomic_set(&tps_rail_state, 1);
    LOG_INF("TPS: EN HIGH, rail ON (addr 0x%02X)", addr);
    k_mutex_unlock(&heater_hw_mutex);
    return 0;
}

static int tps_rail_off(void)
{
    k_mutex_lock(&heater_hw_mutex, K_FOREVER);
    bool was_on = atomic_get(&tps_rail_state) != 0;
    int ret = tps_drive_off_locked();
    if (ret == 0 && was_on) {
        LOG_INF("TPS628682: EN LOW, rail OFF");
    }
    k_mutex_unlock(&heater_hw_mutex);
    if (ret < 0) {
        tps_reset_after_off_failure(ret);
    }
    return ret;
}

static int tps_read_status(uint8_t *status)
{
    if (!status) {
        return -EINVAL;
    }

    k_mutex_lock(&heater_hw_mutex, K_FOREVER);
    int ret = i2c_reg_read_byte(i2c_dev, tps_i2c_addr, TPS_REG_STATUS, status);
    if (ret < 0) {
        uint8_t other = (tps_i2c_addr == TPS_ADDR) ? TPS_ADDR_ALT : TPS_ADDR;
        ret = i2c_reg_read_byte(i2c_dev, other, TPS_REG_STATUS, status);
        if (ret == 0) {
            tps_i2c_addr = other;
        }
    }
    k_mutex_unlock(&heater_hw_mutex);
    return ret;
}

static void heater_force_off(const char *reason, bool latch_fault)
{
    atomic_set(&heater_on_atomic, 0);
    atomic_set(&heater_setpoint_c, 0);
    if (latch_fault) {
        atomic_set(&heater_fault_atomic, 1);
    }
    (void)tps_rail_off();
    if (reason) {
        LOG_WRN("heater force-OFF: %s%s", reason,
                latch_fault ? " (fault latched)" : "");
    }
}

/* Rail OFF, keep the user maintain request. App OFF / disconnect / fault
 * still go through heater_force_off. */
static void heater_pause_rail(const char *reason)
{
    (void)tps_rail_off();
    if (reason) {
        LOG_INF("heater pause: %s", reason);
    }
}

/* ============================================================
 * ================= BLE — FITNESS-BAND STYLE =================
 * ============================================================
 *
 * Design goals (same behaviour as Mi Band / Fitbit class devices):
 *
 *  1. While the device is ON it is ALWAYS reachable:
 *       - not connected  -> advertising (fast, then slow forever)
 *       - connected      -> advertising off (single-link peripheral)
 *  2. After a disconnect (phone walked away, app killed, airplane
 *     mode), advertising restarts automatically and the phone's
 *     background stack can reconnect at any time — hours later.
 *  3. All advertising state changes run in ONE work item on the
 *     system workqueue. bt_le_adv_start() right inside the
 *     disconnected() callback can fail with -ENOMEM because the
 *     connection object is not yet recycled; the work item simply
 *     retries until it succeeds.
 *  4. The connection pointer is only touched under conn_mutex, and
 *     every user takes its own reference (conn_acquire/conn_release).
 *     TX thread and BT RX thread can no longer race.
 */

/* --- Connection parameters (two profiles) ---
 *
 * STREAMING (bulk 10 Hz IMU subscribed):
 *   30–50 ms, latency 0 — radio must wake every event for 129 B notifies.
 *
 * IDLE (connected, bulk CCC off — phone holds link in background):
 *   200–400 ms, latency 4 — effective wake ~1–2 s, ~10–20× less duty.
 *   Must keep CONN_TIMEOUT > interval_max_ms × (latency+1) × 6:
 *     400 ms × 5 × 6 = 12 s  <  20 s supervision. ✓
 *
 * Profiles switch on notify_enabled transitions (bc_ccc_changed + link_tune).
 * Timeout stays 2000 (20 s) in both profiles. */
#define CONN_STREAM_INTERVAL_MIN   24   /* 30 ms  (units of 1.25 ms) */
#define CONN_STREAM_INTERVAL_MAX   40   /* 50 ms */
#define CONN_STREAM_LATENCY         0
#define CONN_IDLE_INTERVAL_MIN    160   /* 200 ms */
#define CONN_IDLE_INTERVAL_MAX    320   /* 400 ms */
#define CONN_IDLE_LATENCY           4
#define CONN_TIMEOUT             2000   /* 20 s   (units of 10 ms)   */
/* Defer param/PHY/DLE/MTU until central discovery settles. Keep this
 * short enough that we do not race the app's encrypted read (~2 s),
 * but past the classic "drop in first 1 s" window. Security is only
 * requested as a fallback if the link is still unencrypted. */
#define LINK_TUNE_DELAY_MS  2000U

/* --- Advertising profile ---
 * FAST: 30-60 ms for 30 s after power-on / disconnect. Snappy
 *   discovery while the user is actively pairing/reconnecting.
 * SLOW: 500-600 ms forever after (was 1000-1200). Still low duty
 *   cycle, much faster phone reconnect after long idle. */
#define ADV_FAST_PERIOD_MS  30000

/* Zephyr 4.x: BT_LE_ADV_OPT_CONN replaces the removed
 * BT_LE_ADV_OPT_CONNECTABLE. It is deliberately ONE-SHOT — the host
 * no longer auto-resumes advertising after a disconnect. That suits
 * this design exactly: OUR adv_work state machine owns every restart
 * (with retry), so nothing races the host's legacy resume logic. */
/*
 * Always advertise openly (no filter accept-list). A previous owner-filter
 * blocked nRF Connect / second phones from even connecting. Single-owner
 * policy is enforced in pairing_accept() instead.
 */
static const struct bt_le_adv_param adv_param_fast = {
    .id           = ISPOON_BT_ID,
    .options      = BT_LE_ADV_OPT_CONN,
    .interval_min = 0x0030,                     /* 30 ms  */
    .interval_max = 0x0060,                     /* 60 ms  */
};

static const struct bt_le_adv_param adv_param_slow = {
    .id           = ISPOON_BT_ID,
    .options      = BT_LE_ADV_OPT_CONN,
    .interval_min = 0x0320,                     /* 500 ms */
    .interval_max = 0x03C0,                     /* 600 ms */
};

#define BC_UUID_SVC_VAL \
    BT_UUID_128_ENCODE(0xf00d0001, 0x1234, 0x5678, 0x9abc, 0xdef012345678)
#define BC_UUID_TX_VAL  \
    BT_UUID_128_ENCODE(0xf00d0002, 0x1234, 0x5678, 0x9abc, 0xdef012345678)
#define BC_UUID_RX_VAL  \
    BT_UUID_128_ENCODE(0xf00d0003, 0x1234, 0x5678, 0x9abc, 0xdef012345678)
#define BC_UUID_DEVICE_ID_VAL \
    BT_UUID_128_ENCODE(0xf00d0004, 0x1234, 0x5678, 0x9abc, 0xdef012345678)
#define BC_UUID_HW_REV_VAL \
    BT_UUID_128_ENCODE(0xf00d0005, 0x1234, 0x5678, 0x9abc, 0xdef012345678)
/* Open (no encrypt) owner/pair status — app can read before bonding. */
#define BC_UUID_OWNER_STATUS_VAL \
    BT_UUID_128_ENCODE(0xf00d0006, 0x1234, 0x5678, 0x9abc, 0xdef012345678)
/* Low-rate event NOTIFY for iOS background (not the 10 Hz bulk stream). */
#define BC_UUID_EVENT_VAL \
    BT_UUID_128_ENCODE(0xf00d0007, 0x1234, 0x5678, 0x9abc, 0xdef012345678)

/* owner_status flags (byte 0) */
#define OWNER_STAT_OWNER_PRESENT   BIT(0) /* device has a stored owner bond */
#define OWNER_STAT_PEER_BONDED     BIT(1) /* this peer is the stored owner */
#define OWNER_STAT_PAIR_REJECTED   BIT(2) /* pairing refused on this link */
#define OWNER_STAT_SECURED         BIT(3) /* L2 encryption active */
#define OWNER_STAT_REPAIR_HOLD_6S  BIT(4) /* owner present, peer not bonded */

static struct bt_uuid_128 bc_uuid_svc = BT_UUID_INIT_128(BC_UUID_SVC_VAL);
static struct bt_uuid_128 bc_uuid_tx  = BT_UUID_INIT_128(BC_UUID_TX_VAL);

/*
 * AD: FLAGS + 128-bit service UUID + SHORTENED name.
 * Scan response: the complete name.
 *
 * The service UUID MUST live in the primary advertisement, not the scan
 * response. Both platforms filter on the primary AD only:
 *
 *   - Android: ScanFilter.setServiceUuid() is pushed into the controller as an
 *     offloaded hardware filter on most chipsets, which sees only the ADV PDU.
 *     With the UUID in the scan response the filter matched NOTHING, so the
 *     app's auto-reconnect scan never found this device and had to fall back to
 *     an unfiltered scan (every BLE device in range, decoded in Dart — far more
 *     radio and CPU for the same result).
 *   - iOS: scanForPeripherals(withServices:) is the ONLY discovery allowed to a
 *     backgrounded app, and in background CoreBluetooth matches service UUIDs
 *     in the primary AD only. UUID in the scan response = no background
 *     discovery on iOS at all, ever.
 *
 * Budget (31 B primary AD): flags 3 + UUID128 18 + short name 8 = 29 B.
 * The full "iSpoon Pro" (12 B encoded) would overflow, so the primary carries
 * the shortened "iSpoon" and the scan response carries the complete name —
 * nRF Connect and the OS still display the full name because both merge the
 * scan response into the advertisement report.
 */
#define ISPOON_ADV_SHORT_NAME "iSpoon"

/* Unassigned Bluetooth CID 0xFFFF + type 0x01 + 8-byte hwinfo Device ID.
 * Scan-response only — primary AD is already at 29/31 bytes. */
#define ISPOON_MFG_COMPANY_ID_LO  0xFF
#define ISPOON_MFG_COMPANY_ID_HI  0xFF
#define ISPOON_MFG_TYPE_DEVICE_ID 0x01
#define ISPOON_MFG_PAYLOAD_LEN    (2 + 1 + 8)

/* Fail the build rather than silently truncating the advertisement: an
 * oversized AD makes bt_le_adv_start() return -EINVAL and the device never
 * advertises at all. 2 B of headroom remain — check here before adding fields. */
BUILD_ASSERT(3 + 18 + 2 + (sizeof(ISPOON_ADV_SHORT_NAME) - 1) <= 31,
             "primary advertising payload exceeds the 31-byte budget");
BUILD_ASSERT((2 + (sizeof(CONFIG_BT_DEVICE_NAME) - 1)) +
             (2 + ISPOON_MFG_PAYLOAD_LEN) <= 31,
             "scan response exceeds the 31-byte budget");

static const struct bt_data ad[] = {
    BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
    BT_DATA_BYTES(BT_DATA_UUID128_ALL, BC_UUID_SVC_VAL),
    BT_DATA(BT_DATA_NAME_SHORTENED, ISPOON_ADV_SHORT_NAME,
            sizeof(ISPOON_ADV_SHORT_NAME) - 1),
};
static uint8_t mfg_payload[ISPOON_MFG_PAYLOAD_LEN];
static struct bt_data sd[2];

static void refresh_scan_response(void)
{
    mfg_payload[0] = ISPOON_MFG_COMPANY_ID_LO;
    mfg_payload[1] = ISPOON_MFG_COMPANY_ID_HI;
    mfg_payload[2] = ISPOON_MFG_TYPE_DEVICE_ID;
    memcpy(&mfg_payload[3], product_device_id, sizeof(product_device_id));

    sd[0].type = BT_DATA_NAME_COMPLETE;
    sd[0].data_len = sizeof(CONFIG_BT_DEVICE_NAME) - 1;
    sd[0].data = (const uint8_t *)CONFIG_BT_DEVICE_NAME;
    sd[1].type = BT_DATA_MANUFACTURER_DATA;
    sd[1].data_len = sizeof(mfg_payload);
    sd[1].data = mfg_payload;
}

/* --- Guarded connection handle --- */

static K_MUTEX_DEFINE(conn_mutex);
static struct bt_conn *current_conn;              /* guarded by conn_mutex */

static atomic_t notify_enabled   = ATOMIC_INIT(0);
static atomic_t ccc_wants_notify = ATOMIC_INIT(0); /* last bulk CCC; restore after L2 */
static atomic_t event_notify_enabled = ATOMIC_INIT(0); /* f00d0007 CCC */
static atomic_t bt_connected     = ATOMIC_INIT(0);  /* read by main loop / UI */
static atomic_t meal_active_atomic = ATOMIC_INIT(0); /* reserved for app meal session */

/* Take a personal reference to the current connection, or NULL.
 * Caller MUST bt_conn_unref() the result when done. */
static struct bt_conn *conn_acquire(void)
{
    struct bt_conn *c = NULL;
    k_mutex_lock(&conn_mutex, K_FOREVER);
    if (current_conn) {
        c = bt_conn_ref(current_conn);
    }
    k_mutex_unlock(&conn_mutex);
    return c;
}

static void owner_bond_count(const struct bt_bond_info *info, void *user_data)
{
    ARG_UNUSED(info);
    ARG_UNUSED(user_data);
    atomic_set(&owner_bond_present, 1);
}

/* Refresh owner_bond_present from NVS bonds (no radio filter). */
static int owner_bond_reload(void)
{
    atomic_set(&owner_bond_present, 0);
    bt_foreach_bond(ISPOON_BT_ID, owner_bond_count, NULL);
    return 0;
}

/* --- Advertising state machine (runs ONLY in adv_work) --- */

enum adv_mode { ADV_OFF = 0, ADV_FAST, ADV_SLOW };

static struct k_work_delayable adv_work;
static enum adv_mode adv_mode_actual;      /* touched only inside adv_work */
static atomic_t      adv_wanted = ATOMIC_INIT(0);   /* 0 = off, 1 = on */
static atomic_t      adv_fast_until32 = ATOMIC_INIT(0);

static bool deadline32_pending(uint32_t deadline, uint32_t now)
{
    return (int32_t)(deadline - now) > 0;
}

static void adv_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);

    bool want_on   = atomic_get(&adv_wanted) != 0;
    bool connected = atomic_get(&bt_connected) != 0;

    /* Connected as (single-link) peripheral -> controller already
     * stopped advertising; just track state. */
    if (!want_on || connected) {
        if (adv_mode_actual != ADV_OFF) {
            bt_le_adv_stop();
            adv_mode_actual = ADV_OFF;
            LOG_INF("ADV: off");
        }
        return;
    }

    uint32_t now = k_uptime_get_32();
    uint32_t fast_until = (uint32_t)atomic_get(&adv_fast_until32);
    enum adv_mode desired =
        deadline32_pending(fast_until, now) ? ADV_FAST : ADV_SLOW;

    if (desired == adv_mode_actual) {
        /* Already in the right mode. If FAST, make sure the downgrade
         * to SLOW is scheduled. */
        if (desired == ADV_FAST) {
            k_work_schedule(&adv_work, K_MSEC((uint32_t)(fast_until - now)));
        }
        return;
    }

    /* Mode change: stop, then start with the new parameters. */
    if (adv_mode_actual != ADV_OFF) {
        bt_le_adv_stop();
        adv_mode_actual = ADV_OFF;
    }

    const struct bt_le_adv_param *p =
        (desired == ADV_FAST) ? &adv_param_fast : &adv_param_slow;

    int err = bt_le_adv_start(p, ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));
    if (err == -ENOMEM || err == -EAGAIN || err == -ECONNREFUSED) {
        /* The just-dropped connection object hasn't been recycled by
         * the host yet — THE classic failure that used to leave v1
         * unconnectable until a power cycle. Retry shortly. */
        LOG_WRN("ADV start busy (%d), retrying", err);
        k_work_schedule(&adv_work, K_MSEC(100));
        return;
    }
    if (err) {
        LOG_ERR("ADV start failed (%d), retrying in 1 s", err);
        k_work_schedule(&adv_work, K_SECONDS(1));
        return;
    }

    adv_mode_actual = desired;
    LOG_INF("ADV: %s", (desired == ADV_FAST) ? "fast" : "slow");

    if (desired == ADV_FAST) {
        k_work_schedule(&adv_work, K_MSEC((uint32_t)(fast_until - now)));
    }
}

/* Request advertising on (with a fresh fast window) or off.
 * Safe to call from any thread. */
static void adv_kick(bool on)
{
    atomic_set(&adv_wanted, on ? 1 : 0);
    if (on) {
        atomic_set(&adv_fast_until32,
                   (atomic_val_t)(k_uptime_get_32() + ADV_FAST_PERIOD_MS));
    }
    k_work_reschedule(&adv_work, K_NO_WAIT);
}

/* --- GATT service --- */

#define BULK_PKT_BYTES_HDR  129  /* full packet; MTU check uses 132 = 129+3 */
/* TX value attr index inside BT_GATT_SERVICE_DEFINE(bc_svc):
 *   0 service, 1 chrc-decl, 2 value, 3 CCC, ... */
#define BC_TX_ATTR_INDEX 2

static void mtu_exchange_cb(struct bt_conn *conn, uint8_t err,
                            struct bt_gatt_exchange_params *params);

static struct bt_gatt_exchange_params mtu_exchange_params = {
    .func = mtu_exchange_cb,
};

/* Apply streaming (bulk on) or idle (bulk off) connection parameters. */
static void conn_apply_params(struct bt_conn *conn, bool streaming)
{
    struct bt_le_conn_param param;

    if (streaming) {
        param.interval_min = CONN_STREAM_INTERVAL_MIN;
        param.interval_max = CONN_STREAM_INTERVAL_MAX;
        param.latency      = CONN_STREAM_LATENCY;
    } else {
        param.interval_min = CONN_IDLE_INTERVAL_MIN;
        param.interval_max = CONN_IDLE_INTERVAL_MAX;
        param.latency      = CONN_IDLE_LATENCY;
    }
    param.timeout = CONN_TIMEOUT;

    int r = bt_conn_le_param_update(conn, &param);
    if (r && r != -EALREADY && r != -EINVAL) {
        LOG_DBG("conn param %s: %d", streaming ? "stream" : "idle", r);
    }
}

/* Event packet (f00d0007) — low-rate status for iOS background. */
#define EVT_PKT_VERSION     1
#define EVT_PKT_SIZE        11
#define EVT_FLAG_VBUS       BIT(0)
#define EVT_FLAG_CHARGING   BIT(1)
#define EVT_FLAG_NTC_OK     BIT(2)
#define EVT_FLAG_IMU_OK     BIT(3)
#define EVT_FLAG_MEAL       BIT(4)
#define EVT_FLAG_HEATER     BIT(5)  /* tps rail actually ON */
#define EVT_FLAG_HEATER_REQ BIT(6)  /* user maintain request (heater_on_atomic) */
#define EVT_PERIOD_MS       30000U
#define EVT_CHECK_MS        2000U

/* Attr index of event value after service table is fully defined:
 * 0 service, 1-2 TX, 3 bulk CCC, 4-5 RX, 6-7 ID, 8-9 HW, 10-11 owner,
 * 12-13 event, 14 event CCC. */
#define BC_EVT_ATTR_INDEX   13

static void event_work_handler(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(event_work, event_work_handler);

static void event_build_packet(uint8_t out[EVT_PKT_SIZE])
{
    uint8_t batt = (uint8_t)atomic_get(&shared_battery_pct);
    int16_t t100 = (int16_t)atomic_get(&shared_temp_c100);
    uint16_t bites = (uint16_t)atomic_get(&shared_bite_count);
    uint32_t ts = k_uptime_get_32();
    uint8_t flags = 0;
    const bool secured = atomic_get(&ble_secured) != 0;

    if ((uint8_t)atomic_get(&npm_cached_vbus_status) & NPM_VBUS_PRESENT) {
        flags |= EVT_FLAG_VBUS;
    }
    if ((uint8_t)atomic_get(&npm_cached_charge_status) & NPM_CHGSTAT_CHARGING) {
        flags |= EVT_FLAG_CHARGING;
    }
    if (atomic_get(&ntc_valid_atomic)) {
        flags |= EVT_FLAG_NTC_OK;
    }
    if (atomic_get(&imu_healthy_atomic)) {
        flags |= EVT_FLAG_IMU_OK;
    }
    if (atomic_get(&meal_active_atomic)) {
        flags |= EVT_FLAG_MEAL;
    }
    if (atomic_get(&tps_rail_state)) {
        flags |= EVT_FLAG_HEATER;
    }
    if (atomic_get(&heater_on_atomic)) {
        flags |= EVT_FLAG_HEATER_REQ;
    }

    /*
     * Battery/temp stay open (iOS background + "Preparing…"). Bite count is
     * behavioural health data — only fill it on an encrypted (owner) link.
     * Unencrypted subscribers receive 0xFFFF so they cannot scrape meals.
     */
    if (!secured) {
        bites = 0xFFFFU;
    }

    out[0] = EVT_PKT_VERSION;
    out[1] = batt;
    out[2] = (uint8_t)t100;
    out[3] = (uint8_t)(t100 >> 8);
    out[4] = (uint8_t)bites;
    out[5] = (uint8_t)(bites >> 8);
    out[6] = flags;
    out[7] = (uint8_t)ts;
    out[8] = (uint8_t)(ts >> 8);
    out[9] = (uint8_t)(ts >> 16);
    out[10] = (uint8_t)(ts >> 24);
}

static void bc_event_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    bool on = (value & BT_GATT_CCC_NOTIFY) != 0U;

    atomic_set(&event_notify_enabled, on ? 1 : 0);
    LOG_INF("Event notifications %s", on ? "enabled" : "disabled");

    if (!on) {
        (void)k_work_cancel_delayable(&event_work);
        return;
    }

    /* Immediate push via CCC's preceding value attribute (attr - 1). */
    struct bt_conn *conn = conn_acquire();
    if (conn) {
        uint8_t pkt[EVT_PKT_SIZE];

        event_build_packet(pkt);
        int r = bt_gatt_notify(conn, attr - 1, pkt, sizeof(pkt));
        if (r) {
            LOG_DBG("event immediate notify: %d", r);
        }
        bt_conn_unref(conn);
    }
    k_work_reschedule(&event_work, K_MSEC(EVT_CHECK_MS));
}

static void bc_ccc_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    /*
     * nRF Connect (and some stacks) write 0x0003 (notify|indicate) even when
     * only NOTIFY is supported. Matching == BT_GATT_CCC_NOTIFY (0x0001) alone
     * left the stream armed OFF while the phone showed "Notifications enabled".
     */
    bool on = (value & BT_GATT_CCC_NOTIFY) != 0U;

    atomic_set(&ccc_wants_notify, on ? 1 : 0);
    /*
     * TX stream arms on CCC alone so nRF Connect (and the app) see live
     * notifications without waiting for LESC. Heater RX + Device ID + HW rev
     * remain encrypt-gated.
     */
    atomic_set(&notify_enabled, on ? 1 : 0);
    LOG_INF("Bulk notifications %s (ccc=0x%04x secured=%d)",
            on ? "enabled" : "disabled",
            value,
            (int)atomic_get(&ble_secured));

    struct bt_conn *conn = conn_acquire();
    if (!conn) {
        return;
    }

    /* P1: streaming params while bulk is on; idle when bulk CCC is off. */
    conn_apply_params(conn, on);

    if (!on) {
        bt_conn_unref(conn);
        return;
    }

    /* App/nRF Connect just subscribed: raise MTU + start Just Works. */
    int r = bt_gatt_exchange_mtu(conn, &mtu_exchange_params);
    if (r && r != -EALREADY) {
        LOG_WRN("CCC: MTU exchange %d", r);
    }
    if (bt_conn_get_security(conn) < BT_SECURITY_L2) {
        r = bt_conn_set_security(conn, BT_SECURITY_L2);
        if (r && r != -EALREADY) {
            LOG_WRN("CCC: set_security %d", r);
        }
    }

    /* Immediate 9-byte header so nRF Connect proves the notify path works
     * even before the first 10-sample IMU batch is ready. CCC attr is
     * after the value attr in the service table, so value = attr - 1. */
    {
        uint8_t hb[9];
        uint8_t batt = (uint8_t)atomic_get(&shared_battery_pct);
        int16_t t100 = (int16_t)atomic_get(&shared_temp_c100);
        uint32_t ts = k_uptime_get_32();
        uint16_t bites = (uint16_t)atomic_get(&shared_bite_count);
        hb[0] = batt;
        hb[1] = (uint8_t)t100;
        hb[2] = (uint8_t)(t100 >> 8);
        hb[3] = (uint8_t)ts;
        hb[4] = (uint8_t)(ts >> 8);
        hb[5] = (uint8_t)(ts >> 16);
        hb[6] = (uint8_t)(ts >> 24);
        hb[7] = (uint8_t)bites;
        hb[8] = (uint8_t)(bites >> 8);
        r = bt_gatt_notify(conn, attr - 1, hb, sizeof(hb));
        if (r) {
            LOG_WRN("CCC: immediate notify %d", r);
        }
    }

    bt_conn_unref(conn);
}

/* Heater commands — ON actuation is owned by the safety supervisor. */
static ssize_t bc_rx_write(struct bt_conn *conn,
                           const struct bt_gatt_attr *attr,
                           const void *buf, uint16_t len,
                           uint16_t offset, uint8_t flags)
{
    ARG_UNUSED(attr);
    ARG_UNUSED(flags);

    /*
     * Never return application ATT errors (UNLIKELY / VALUE_NOT_ALLOWED /
     * INSUFFICIENT_ENCRYPTION) from this callback. Android treats a failed
     * write-with-response as a GATT failure and drops the ACL — that is
     * "Apply Settings → device disconnected". Characteristic permissions
     * already require encrypt+LESC; if this callback runs, ACK the write.
     * If the rail cannot start, ignore the ON and keep the link.
     */
    if (offset != 0 || len == 0 || len > 8) {
        return (ssize_t)(len == 0 ? 0 : len);
    }

    const char *cmd = (const char *)buf;

    /* Panel polarity for the fitted glass: "INV 0" / "INV 1". Only parked
     * here — the UI thread owns the panel SPI (no lock), so applying it from
     * this callback would tear a frame. */
    if (len == 5 && memcmp(cmd, "INV ", 4) == 0 &&
        (cmd[4] == '0' || cmd[4] == '1')) {
        atomic_set(&panel_invert_req, (atomic_val_t)(cmd[4] - '0'));
        return len;
    }

    if (len == 3 && memcmp(cmd, "OFF", 3) == 0) {
        /* Connected GATT write is enough to stop heat. Do not require L2 —
         * that left the rail stuck on if pairing lagged. */
        heater_force_off("OFF command", false);
        LOG_INF("heater: OFF");
        return len;
    }

    int sp = 0;
    bool parsed_on = false;

    if (len == 2 && memcmp(cmd, "ON", 2) == 0) {
        sp = 0;
        parsed_on = true;
    } else if (len == 5 &&
               cmd[0] == 'O' && cmd[1] == 'N' && cmd[2] == ' ' &&
               cmd[3] >= '0' && cmd[3] <= '9' &&
               cmd[4] >= '0' && cmd[4] <= '9') {
        sp = (cmd[3] - '0') * 10 + (cmd[4] - '0');
        if (sp < HEATER_SETPOINT_MIN_C || sp > HEATER_SETPOINT_MAX_C) {
            LOG_WRN("heater: ON ignored, setpoint %d C out of range", sp);
            return len;
        }
        parsed_on = true;
    } else {
        LOG_WRN("heater: malformed command ignored");
        return len;
    }

    if (!parsed_on) {
        return len;
    }

    if (!atomic_get(&tps_ready_atomic) ||
        !atomic_get(&battery_status_valid) ||
        atomic_get(&dfu_locked_atomic) ||
        atomic_get(&heater_fault_atomic)) {
        LOG_WRN("heater: ON ignored, safety preconditions not met");
        return len;
    }

    /*
     * ST-Link bench: setting heater_on + a live link flag raised P0.15 and
     * the TPS ACK'd 0x46. The app path used to ACK ON then drop it unless
     * ble_secured was already 1. IMU CCC streams without L2, so Apply
     * looked successful and the flame stayed off. A connected GATT ON is
     * the same operator command — arm the rail; disconnect still force-offs.
     */
    if (bt_conn_get_security(conn) >= BT_SECURITY_L2) {
        atomic_set(&ble_secured, 1);
    } else {
        (void)bt_conn_set_security(conn, BT_SECURITY_L2);
        atomic_set(&ble_secured, 1);
    }
    atomic_set(&heater_setpoint_c, sp);
    atomic_set(&heater_on_atomic, 1);
    LOG_INF("heater: ON%s", sp ? " with bounded setpoint" : " (5 min maximum)");
    return len;
}

static ssize_t read_device_id(struct bt_conn *conn,
                              const struct bt_gatt_attr *attr,
                              void *buf, uint16_t len, uint16_t offset)
{
    ARG_UNUSED(conn);
    return bt_gatt_attr_read(conn, attr, buf, len, offset,
                             product_device_id, sizeof(product_device_id));
}

static ssize_t read_hw_revision(struct bt_conn *conn,
                                const struct bt_gatt_attr *attr,
                                void *buf, uint16_t len, uint16_t offset)
{
    if (bt_conn_get_security(conn) < BT_SECURITY_L2 ||
        !atomic_get(&ble_secured)) {
        return BT_GATT_ERR(BT_ATT_ERR_INSUFFICIENT_ENCRYPTION);
    }

    return bt_gatt_attr_read(conn, attr, buf, len, offset,
                             CONFIG_ISPOON_HW_REV,
                             sizeof(CONFIG_ISPOON_HW_REV) - 1);
}

/*
 * Open (unencrypted) owner/pair status. App reads this before bonding to
 * distinguish "need Just Works" vs "owner present — hold 6 s to re-pair".
 *
 *   payload[0] flags:
 *     bit0 OWNER_PRESENT   device has a stored owner bond
 *     bit1 PEER_BONDED     this peer is the stored owner
 *     bit2 PAIR_REJECTED   pairing refused on this ACL (owner busy)
 *     bit3 SECURED         L2 encryption active
 *     bit4 REPAIR_HOLD_6S  owner present and this peer is not owner
 *   payload[1] last reject reason (bt_security_err), 0 if none
 */
static ssize_t read_owner_status(struct bt_conn *conn,
                                 const struct bt_gatt_attr *attr,
                                 void *buf, uint16_t len, uint16_t offset)
{
    uint8_t payload[2] = { 0, 0 };
    bool owner = atomic_get(&owner_bond_present) != 0;
    bool peer_bonded = false;

    if (conn) {
        const bt_addr_le_t *peer = bt_conn_get_dst(conn);
        if (peer) {
            peer_bonded = bt_le_bond_exists(ISPOON_BT_ID, peer);
        }
    }

    if (owner) {
        payload[0] |= OWNER_STAT_OWNER_PRESENT;
    }
    if (peer_bonded) {
        payload[0] |= OWNER_STAT_PEER_BONDED;
    }
    if (atomic_get(&pair_reject_latched)) {
        payload[0] |= OWNER_STAT_PAIR_REJECTED;
    }
    if (atomic_get(&ble_secured)) {
        payload[0] |= OWNER_STAT_SECURED;
    }
    if (owner && !peer_bonded) {
        payload[0] |= OWNER_STAT_REPAIR_HOLD_6S;
    }
    payload[1] = (uint8_t)atomic_get(&pair_reject_reason);

    return bt_gatt_attr_read(conn, attr, buf, len, offset,
                             payload, sizeof(payload));
}

/*
 * TX stream + CCC: CCC may be written before L2 (so the OS can start the
 * Just Works flow). HW rev still requires encrypt+LESC (pairing trigger).
 * Heater RX is OPEN write: ATT WRITE_ENCRYPT made Android drop the ACL on
 * Apply Settings. A connected GATT ON/OFF arms/stops the rail the same
 * way the ST-Link RAM poke did; disconnect still force-offs. Device ID /
 * owner status stay open-read.
 */
#define BC_TX_SEC     (BT_GATT_PERM_READ)
#define BC_CCC_SEC    (BT_GATT_PERM_READ | BT_GATT_PERM_WRITE)
#define BC_READ_SEC   (BT_GATT_PERM_READ_ENCRYPT | BT_GATT_PERM_READ_LESC)
#define BC_WRITE_SEC  (BT_GATT_PERM_WRITE_ENCRYPT | BT_GATT_PERM_WRITE_LESC)
#define BC_OPEN_READ  (BT_GATT_PERM_READ)
#define BC_OPEN_WRITE (BT_GATT_PERM_WRITE)

BT_GATT_SERVICE_DEFINE(bc_svc,
    BT_GATT_PRIMARY_SERVICE(&bc_uuid_svc),
    BT_GATT_CHARACTERISTIC(&bc_uuid_tx.uuid,
                           BT_GATT_CHRC_NOTIFY,
                           BC_TX_SEC,
                           NULL, NULL, NULL),
    BT_GATT_CCC(bc_ccc_changed, BC_CCC_SEC),
    BT_GATT_CHARACTERISTIC(BT_UUID_DECLARE_128(BC_UUID_RX_VAL),
                           BT_GATT_CHRC_WRITE,
                           BC_OPEN_WRITE,
                           NULL, bc_rx_write, NULL),
    BT_GATT_CHARACTERISTIC(BT_UUID_DECLARE_128(BC_UUID_DEVICE_ID_VAL),
                           BT_GATT_CHRC_READ,
                           BC_OPEN_READ,
                           read_device_id, NULL, NULL),
    BT_GATT_CHARACTERISTIC(BT_UUID_DECLARE_128(BC_UUID_HW_REV_VAL),
                           BT_GATT_CHRC_READ,
                           BC_READ_SEC,
                           read_hw_revision, NULL, NULL),
    BT_GATT_CHARACTERISTIC(BT_UUID_DECLARE_128(BC_UUID_OWNER_STATUS_VAL),
                           BT_GATT_CHRC_READ,
                           BC_OPEN_READ,
                           read_owner_status, NULL, NULL),
    /* Low-rate event stream for iOS background (not 10 Hz bulk). */
    BT_GATT_CHARACTERISTIC(BT_UUID_DECLARE_128(BC_UUID_EVENT_VAL),
                           BT_GATT_CHRC_NOTIFY,
                           BC_TX_SEC,
                           NULL, NULL, NULL),
    BT_GATT_CCC(bc_event_ccc_changed, BC_CCC_SEC),
);

/* Defined after bc_svc so attrs[] is visible. */
static void event_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);
    static uint8_t last_batt = 0xFF;
    static uint16_t last_bites = 0xFFFF;
    static uint8_t last_flags = 0xFF;
    static int64_t last_force_ms;

    if (!atomic_get(&bt_connected) || !atomic_get(&event_notify_enabled)) {
        return;
    }

    struct bt_conn *conn = conn_acquire();
    if (!conn) {
        k_work_reschedule(&event_work, K_MSEC(EVT_CHECK_MS));
        return;
    }

    uint8_t pkt[EVT_PKT_SIZE];
    event_build_packet(pkt);

    bool changed = (pkt[1] != last_batt) ||
                   (pkt[4] != (uint8_t)last_bites) ||
                   (pkt[5] != (uint8_t)(last_bites >> 8)) ||
                   (pkt[6] != last_flags);
    int64_t now = k_uptime_get();
    bool due = (last_force_ms == 0) ||
               ((now - last_force_ms) >= (int64_t)EVT_PERIOD_MS);

    if (changed || due) {
        int r = bt_gatt_notify(conn, &bc_svc.attrs[BC_EVT_ATTR_INDEX],
                               pkt, sizeof(pkt));
        if (r == 0) {
            last_batt = pkt[1];
            last_bites = (uint16_t)pkt[4] | ((uint16_t)pkt[5] << 8);
            last_flags = pkt[6];
            last_force_ms = now;
        }
    }

    bt_conn_unref(conn);
    k_work_reschedule(&event_work, K_MSEC(EVT_CHECK_MS));
}

/* --- Bulk packet sizing --- */
#define IMU_SAMPLE_BYTES    12
#define IMU_SAMPLES_PER_PKT 10
#define BULK_PKT_BYTES      (1 + 2 + 4 + 2 + (IMU_SAMPLE_BYTES * IMU_SAMPLES_PER_PKT))
BUILD_ASSERT(BULK_PKT_BYTES == 129, "Packet size must be exactly 129 bytes");
BUILD_ASSERT(BULK_PKT_BYTES == BULK_PKT_BYTES_HDR, "packet size mismatch");

/* --- Link tuning after connect: MTU + PHY + DLE + conn params --- */

static void mtu_exchange_cb(struct bt_conn *conn, uint8_t err,
                            struct bt_gatt_exchange_params *params)
{
    ARG_UNUSED(params);
    if (err) {
        LOG_WRN("MTU exchange failed (%u)", err);
        return;
    }
    uint16_t mtu = bt_gatt_get_mtu(conn);
    if (mtu >= BULK_PKT_BYTES + 3) {
        LOG_INF("MTU=%u — bulk packets OK", mtu);
    } else {
        LOG_WRN("MTU=%u, need >= %u — holding full 129 B until MTU grows",
                mtu, BULK_PKT_BYTES + 3);
    }
}

static K_SEM_DEFINE(disconnect_sem, 0, 1);

static enum bt_security_err pairing_accept(
    struct bt_conn *conn,
    const struct bt_conn_pairing_feat *const feat)
{
    ARG_UNUSED(feat);

    const bt_addr_le_t *peer = bt_conn_get_dst(conn);
    if (bt_le_bond_exists(ISPOON_BT_ID, peer)) {
        return BT_SECURITY_ERR_SUCCESS;
    }

    /*
     * Single-owner policy: a bonded spoon rejects new peers until the
     * legitimate owner clears the bond with a 6 s physical long-hold.
     * Never auto-unpair here — that allowed any nearby phone to steal
     * heater + DFU control after a momentary RF drop.
     */
    if (atomic_get(&owner_bond_present)) {
        /* Latch a readable signal so the app can show "hold 6 s" instead
         * of spinning on notify_enabled=0 / silent pair failure. */
        atomic_set(&pair_reject_latched, 1);
        atomic_set(&pair_reject_reason,
                   (atomic_val_t)BT_SECURITY_ERR_PAIR_NOT_ALLOWED);
        LOG_WRN("Rejecting new peer — owner bond present (use long-hold reset)");
        return BT_SECURITY_ERR_PAIR_NOT_ALLOWED;
    }

    return BT_SECURITY_ERR_SUCCESS;
}

static void auth_cancel(struct bt_conn *conn)
{
    ARG_UNUSED(conn);
    LOG_WRN("Pairing cancelled (link kept — central may retry)");
}

/* No display PIN callback — OS Just Works LESC bonding only. */
static struct bt_conn_auth_cb auth_callbacks = {
    .pairing_accept = pairing_accept,
    .cancel = auth_cancel,
};

static void pairing_complete(struct bt_conn *conn, bool bonded)
{
    ARG_UNUSED(conn);

    if (!bonded) {
        LOG_WRN("Pairing finished without bond (link kept)");
        return;
    }

    LOG_INF("Owner bond stored (Just Works, no PIN)");
    owner_bond_reload();
    /* Bond stored implies L2 is available; arm stream if CCC already on
     * (some stacks fire pairing_complete before security_changed). */
    atomic_set(&ble_secured, 1);
    if (atomic_get(&ccc_wants_notify)) {
        atomic_set(&notify_enabled, 1);
    }
}

static void pairing_failed(struct bt_conn *conn, enum bt_security_err reason)
{
    ARG_UNUSED(conn);
    /* Do NOT disconnect — nRF Connect must stay linked to show services. */
    LOG_WRN("Pairing failed (%d) — keeping connection", reason);
    atomic_set(&ble_secured, 0);
}

static struct bt_conn_auth_info_cb auth_info_callbacks = {
    .pairing_complete = pairing_complete,
    .pairing_failed = pairing_failed,
};

static void security_changed(struct bt_conn *conn, bt_security_t level,
                             enum bt_security_err err)
{
    /*
     * Trust the resulting security *level*, not only err==0. A soft
     * re-encrypt error on an already-L2 link must not drop ble_secured
     * (heater unlock + encrypted ATT). Clear only when level falls below L2.
     */
    if (level >= BT_SECURITY_L2) {
        atomic_set(&ble_secured, 1);
        /* CCC alone already arms TX; keep notify on if subscribed. */
        if (atomic_get(&ccc_wants_notify)) {
            atomic_set(&notify_enabled, 1);
        }
        LOG_INF("BLE encrypted at security level %u (err=%d)", level, err);
        /* Re-nudge MTU now that the link is encrypted — Android often
         * finalises ATT MTU only after bonding. */
        if (conn) {
            int r = bt_gatt_exchange_mtu(conn, &mtu_exchange_params);
            if (r && r != -EALREADY) {
                LOG_DBG("post-encrypt MTU exchange: %d", r);
            }
        }
        return;
    }

    /* Keep the ACL link up. TX already streams pre-bond. Heater now follows
     * bt_connected (GATT ON), not L2 — killing the rail here is why Apply
     * never showed a flame while IMU was live. Identity stays encrypt-gated. */
    atomic_set(&ble_secured, 0);
    LOG_WRN("BLE security level %u err %d — connection kept (TX still allowed)",
            level, err);
}

static void link_tune_work_handler(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(link_tune_work, link_tune_work_handler);

/* Run AFTER central service discovery has settled (see LINK_TUNE_DELAY_MS).
 * Order: radio params first, then MTU, then security only as fallback if
 * the central has not already driven L2 (CCC / encrypted char access). */
static void link_tune_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);

    struct bt_conn *conn = conn_acquire();
    if (!conn) {
        return;
    }

    /* Prefer idle at first link-tune (bulk CCC usually still off). Streaming
     * is applied immediately when bulk CCC enables. */
    conn_apply_params(conn, atomic_get(&notify_enabled) != 0);
    int r = 0;

#if defined(CONFIG_BT_USER_PHY_UPDATE)
    r = bt_conn_le_phy_update(conn, BT_CONN_LE_PHY_PARAM_2M);
    if (r && r != -EALREADY) {
        LOG_DBG("PHY update: %d (non-fatal)", r);
    }
#endif

#if defined(CONFIG_BT_USER_DATA_LEN_UPDATE)
    r = bt_conn_le_data_len_update(conn, BT_LE_DATA_LEN_PARAM_MAX);
    if (r && r != -EALREADY) {
        LOG_DBG("DLE update: %d (non-fatal)", r);
    }
#endif

    r = bt_gatt_exchange_mtu(conn, &mtu_exchange_params);
    if (r && r != -EALREADY) {
        LOG_WRN("bt_gatt_exchange_mtu: %d", r);
    }

    /* Fallback only — app/CCC usually start encryption first. Avoids a
     * second concurrent security procedure racing the central. */
    if (bt_conn_get_security(conn) < BT_SECURITY_L2 &&
        !atomic_get(&ble_secured)) {
        r = bt_conn_set_security(conn, BT_SECURITY_L2);
        if (r && r != -EALREADY) {
            LOG_WRN("deferred set_security: %d (non-fatal)", r);
        }
    }

    bt_conn_unref(conn);
}

/* While the phone is connected, keep encryption + MTU + notify flags healthy.
 * Without this, a missed security_changed or a late Android MTU leaves
 * notify_enabled=0 / MTU=23 and the app receives zero packets forever. */
#define STREAM_HEALTH_PERIOD_MS  500U

static void stream_health_work_handler(struct k_work *work);
static K_WORK_DELAYABLE_DEFINE(stream_health_work, stream_health_work_handler);

static void stream_health_work_handler(struct k_work *work)
{
    ARG_UNUSED(work);

    if (!atomic_get(&bt_connected)) {
        return;
    }

    struct bt_conn *conn = conn_acquire();
    if (!conn) {
        k_work_reschedule(&stream_health_work, K_MSEC(STREAM_HEALTH_PERIOD_MS));
        return;
    }

    /* 1) Resync secured flag from the controller. */
    if (bt_conn_get_security(conn) >= BT_SECURITY_L2) {
        if (!atomic_get(&ble_secured)) {
            atomic_set(&ble_secured, 1);
            LOG_INF("stream_health: L2 detected, arming ble_secured");
        }
        if (atomic_get(&ccc_wants_notify) && !atomic_get(&notify_enabled)) {
            atomic_set(&notify_enabled, 1);
            LOG_INF("stream_health: CCC+L2 → notify_enabled");
        }
    } else if (atomic_get(&ccc_wants_notify) &&
               !atomic_get(&pair_reject_latched)) {
        /* App subscribed for data and pairing is allowed — keep asking L2. */
        int r = bt_conn_set_security(conn, BT_SECURITY_L2);
        if (r && r != -EALREADY && r != -EBUSY) {
            LOG_DBG("stream_health set_security: %d", r);
        }
    }

    /* 2) Keep raising ATT MTU until 129 B bulk packets fit. */
    uint16_t mtu = bt_gatt_get_mtu(conn);
    if (mtu < (uint16_t)(BULK_PKT_BYTES + 3U)) {
        int r = bt_gatt_exchange_mtu(conn, &mtu_exchange_params);
        if (r && r != -EALREADY && r != -EBUSY) {
            LOG_DBG("stream_health MTU exchange: %d (mtu=%u)", r, mtu);
        }
    }

    bt_conn_unref(conn);
    k_work_reschedule(&stream_health_work, K_MSEC(STREAM_HEALTH_PERIOD_MS));
}

static void connected(struct bt_conn *conn, uint8_t err)
{
    if (err) {
        LOG_ERR("BLE connection failed (%u)", err);
        k_work_reschedule(&adv_work, K_NO_WAIT);
        return;
    }

    k_mutex_lock(&conn_mutex, K_FOREVER);
    current_conn = bt_conn_ref(conn);
    k_mutex_unlock(&conn_mutex);

    atomic_set(&bt_connected, 1);
    atomic_set(&ble_secured, 0);
    atomic_set(&pair_reject_latched, 0);
    atomic_set(&pair_reject_reason, 0);
    /* status_update() on the main loop paints green BT icon from this flag. */
    LOG_INF("BLE connected (UI BT icon) — link tune in %u ms",
            LINK_TUNE_DELAY_MS);

    /* Stop advertising while connected. */
    k_work_reschedule(&adv_work, K_NO_WAIT);

    /*
     * Critical: do NOT request security / conn-param / PHY / DLE here.
     * nRF Connect starts GATT discovery immediately; updates in the first
     * ~1 s cause the classic "connect then drop after one second".
     */
    k_work_reschedule(&link_tune_work, K_MSEC(LINK_TUNE_DELAY_MS));
    k_work_reschedule(&stream_health_work, K_MSEC(STREAM_HEALTH_PERIOD_MS));
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
    ARG_UNUSED(conn);
    LOG_INF("BLE disconnected (reason 0x%02X)", reason);

    (void)k_work_cancel_delayable(&link_tune_work);
    (void)k_work_cancel_delayable(&stream_health_work);

    atomic_set(&notify_enabled, 0);
    atomic_set(&ccc_wants_notify, 0);
    atomic_set(&event_notify_enabled, 0);
    atomic_set(&bt_connected, 0);
    atomic_set(&ble_secured, 0);
    (void)k_work_cancel_delayable(&event_work);
    heater_force_off("BLE disconnected", false);

    k_mutex_lock(&conn_mutex, K_FOREVER);
    if (current_conn) {
        bt_conn_unref(current_conn);
        current_conn = NULL;
    }
    k_mutex_unlock(&conn_mutex);

    /* Wake anyone waiting for a clean shutdown. */
    k_sem_give(&disconnect_sem);

    /* Fitness-band behaviour: if the device is still on, immediately
     * re-open a FAST advertising window so the phone (foreground OR
     * background) can reconnect at once; falls back to slow adv after
     * 30 s. All actual radio work happens in adv_work with retries. */
    if (atomic_get(&adv_wanted)) {
        atomic_set(&adv_fast_until32,
                   (atomic_val_t)(k_uptime_get_32() + ADV_FAST_PERIOD_MS));
        k_work_reschedule(&adv_work, K_NO_WAIT);
    }
}

/* Optional but recommended on NCS 3.1: the `recycled` callback fires
 * when the connection object is actually freed — the perfect moment
 * to (re)start advertising with zero -ENOMEM risk. */
static void recycled(void)
{
    k_work_reschedule(&adv_work, K_NO_WAIT);
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
    .connected    = connected,
    .disconnected = disconnected,
    .security_changed = security_changed,
    .recycled     = recycled,
};

static int product_device_identity_init(void)
{
    memset(product_device_id, 0, sizeof(product_device_id));
    ssize_t count = hwinfo_get_device_id(product_device_id,
                                         sizeof(product_device_id));
    if (count <= 0) {
        return -EIO;
    }

    uint8_t combined = 0;
    for (size_t i = 0; i < sizeof(product_device_id); i++) {
        combined |= product_device_id[i];
    }
    if (combined == 0U) {
        return -EIO;
    }

    refresh_scan_response();
    return 0;
}

static int ensure_product_bt_identity(void)
{
    size_t count = 0;
    bt_id_get(NULL, &count);

    while (count <= ISPOON_BT_ID) {
        int id = bt_id_create(NULL, NULL);
        if (id < 0) {
            return id;
        }
        bt_id_get(NULL, &count);
        if (id > ISPOON_BT_ID) {
            return -EIO;
        }
    }

    return 0;
}

static int ble_setup(void)
{
    k_work_init_delayable(&adv_work, adv_work_handler);

    int err = product_device_identity_init();
    if (err) {
        LOG_ERR("Stable product Device ID unavailable (%d)", err);
        return err;
    }

    err = bt_enable(NULL);
    if (err) {
        LOG_ERR("bt_enable failed (%d)", err);
        return err;
    }
    err = bt_conn_auth_cb_register(&auth_callbacks);
    if (err) {
        LOG_ERR("BLE auth callback registration failed (%d)", err);
        return err;
    }

    err = bt_conn_auth_info_cb_register(&auth_info_callbacks);
    if (err) {
        LOG_ERR("BLE auth-info callback registration failed (%d)", err);
        return err;
    }

    err = settings_load();
    if (err) {
        /* Do not block advertising if NVS is empty/corrupt after flash. */
        LOG_WRN("settings_load failed (%d) — continuing without bonds", err);
    }

    err = ensure_product_bt_identity();
    if (err) {
        LOG_ERR("Product BLE identity unavailable (%d)", err);
        return err;
    }

    (void)owner_bond_reload();

    LOG_INF("BLE stack ready, device name '%s', owner=%s",
            CONFIG_BT_DEVICE_NAME,
            atomic_get(&owner_bond_present) ? "bonded" : "unowned");
    return 0;
}

/* Ownership recovery for a lost/replaced phone: continuous long hold while
 * the device is ON. Double-tap is reserved for power on/off, so bond reset
 * is a deliberate 6 s press. A remote peer cannot invoke this path.
 *
 * Keep the product static identity address stable — only clear bonds.
 * Rotating the MAC (old bt_id_reset) orphaned the phone's bond table and
 * the app's saved address on every reset. */
static void owner_bond_reset_perform(void)
{
    if (!atomic_get(&owner_bond_present)) {
        return;
    }

    /* Unpair all bonds on the product identity; do NOT rotate the address. */
    int err = bt_unpair(ISPOON_BT_ID, NULL);
    if (err) {
        LOG_ERR("Owner bond reset failed (%d)", err);
        fill_color(COLOR_BG);
        draw_text_small_at(UI_SAFE_X0, UI_SAFE_Y0 + 44, "RESET FAILED", COLOR_RED, COLOR_BG);
        k_msleep(1000);
        return;
    }

    atomic_set(&pair_reject_latched, 0);
    atomic_set(&pair_reject_reason, 0);
    owner_bond_reload();
    LOG_WRN("Owner bond cleared by physical long-hold (MAC unchanged)");
    fill_color(COLOR_BG);
    draw_text_small_at(UI_SAFE_X0, UI_SAFE_Y0 + 44, "OWNER CLEARED", COLOR_FG, COLOR_BG);
    k_msleep(1000);
}

/* Kept for boot-path compatibility: only if the pad is still held after the
 * double-tap wake sequence (unusual). Primary path is long-hold in the UI. */
static void maybe_reset_owner_bond(void)
{
    if (!atomic_get(&owner_bond_present) ||
        gpio_pin_get(gpio0, TOUCH_PIN) != 1) {
        return;
    }

    fill_color(COLOR_BG);
    draw_text_small_at(UI_SAFE_X0, UI_SAFE_Y0 + 14, "KEEP HOLD", COLOR_FG, COLOR_BG);
    draw_text_small_at(UI_SAFE_X0, UI_SAFE_Y0 + 28, "RESET OWNER", COLOR_FG, COLOR_BG);

    int64_t started = k_uptime_get();
    while (gpio_pin_get(gpio0, TOUCH_PIN) == 1) {
        watchdog_feed_main();
        if ((k_uptime_get() - started) >= OWNER_RESET_HOLD_MS) {
            owner_bond_reset_perform();
            return;
        }
        k_msleep(20);
    }
}

/* Clean, CONFIRMED teardown before System OFF.
 *
 * v1 fired bt_conn_disconnect() and slept a fixed 50 ms, then killed
 * the radio — at a 200 ms connection interval the LL_TERMINATE_IND
 * often never made it out, so the phone sat through a 4 s supervision
 * timeout and reported "connection lost" instead of a clean close.
 *
 * Now we wait on disconnect_sem (given by the disconnected callback)
 * with a 1 s ceiling. */
static void ble_shutdown(void)
{
    adv_kick(false);
    /* Let the adv work item run once so advertising really stops. */
    k_msleep(20);

    struct bt_conn *conn = conn_acquire();
    if (conn) {
        k_sem_reset(&disconnect_sem);
        int err = bt_conn_disconnect(conn, BT_HCI_ERR_REMOTE_USER_TERM_CONN);
        bt_conn_unref(conn);
        if (err == 0) {
            if (k_sem_take(&disconnect_sem, K_MSEC(1000)) != 0) {
                LOG_WRN("Disconnect not confirmed within 1 s");
            }
        }
    }
}

static enum mgmt_cb_return dfu_mgmt_callback(
    uint32_t event, enum mgmt_cb_return prev_status,
    int32_t *rc, uint16_t *group, bool *abort_more,
    void *data, size_t data_size)
{
    ARG_UNUSED(prev_status);
    ARG_UNUSED(group);
    ARG_UNUSED(abort_more);
    ARG_UNUSED(data);
    ARG_UNUSED(data_size);

    if (event == MGMT_EVT_OP_IMG_MGMT_DFU_CHUNK) {
        /* Reject while heating — do NOT force the rail off on the reject
         * path. A DFU probe must not kill an in-progress heat cycle; the
         * app is required to send OFF before starting SMP upload. */
        if (atomic_get(&heater_on_atomic) ||
            atomic_get(&tps_rail_state)) {
            *rc = MGMT_ERR_EBUSY;
            return MGMT_CB_ERROR_RC;
        }

        atomic_set(&dfu_locked_atomic, 1);
        /* Belt-and-braces: keep heater off for the whole upload. */
        heater_force_off("DFU upload active", false);
    } else if (event == MGMT_EVT_OP_IMG_MGMT_DFU_PENDING) {
        /* Image staged for TEST boot. Keep heater locked until reboot;
         * STOPPED must not unlock after this. */
        atomic_set(&dfu_pending_atomic, 1);
        atomic_set(&dfu_locked_atomic, 1);
        heater_force_off("DFU image pending", false);
    } else if (event == MGMT_EVT_OP_IMG_MGMT_DFU_STOPPED) {
        /* Unlock only on abort/failure. Successful uploads may emit
         * STOPPED before or after PENDING; never clear once PENDING. */
        if (!atomic_get(&dfu_pending_atomic)) {
            atomic_set(&dfu_locked_atomic, 0);
        }
    }

    return MGMT_CB_OK;
}

static struct mgmt_callback dfu_mgmt_cb = {
    .callback = dfu_mgmt_callback,
    .event_id = MGMT_EVT_OP_IMG_MGMT_DFU_CHUNK |
                MGMT_EVT_OP_IMG_MGMT_DFU_STOPPED |
                MGMT_EVT_OP_IMG_MGMT_DFU_PENDING,
};

static enum mgmt_cb_return reset_mgmt_callback(
    uint32_t event, enum mgmt_cb_return prev_status,
    int32_t *rc, uint16_t *group, bool *abort_more,
    void *data, size_t data_size)
{
    ARG_UNUSED(prev_status);
    ARG_UNUSED(group);
    ARG_UNUSED(abort_more);
    ARG_UNUSED(data);
    ARG_UNUSED(data_size);

    if (event != MGMT_EVT_OP_OS_MGMT_RESET) {
        return MGMT_CB_OK;
    }

    heater_force_off("MCUmgr reset request", false);
    /* FET is off. Nordic Device Manager then issues OS_MGMT reset to TEST-boot
     * the staged image — never EBUSY that command after a successful upload. */
    return MGMT_CB_OK;
}

static struct mgmt_callback reset_mgmt_cb = {
    .callback = reset_mgmt_callback,
    .event_id = MGMT_EVT_OP_OS_MGMT_RESET,
};

static int watchdog_start(void)
{
    if (!device_is_ready(watchdog_dev)) {
        LOG_ERR("Hardware watchdog is not ready");
        return -ENODEV;
    }

    const struct wdt_timeout_cfg timeout = {
        .window = {
            .min = 0,
            .max = MAIN_WATCHDOG_TIMEOUT_MS,
        },
        .callback = NULL,
        .flags = WDT_FLAG_RESET_SOC,
    };

    watchdog_main_channel = wdt_install_timeout(watchdog_dev, &timeout);
    if (watchdog_main_channel < 0) {
        LOG_ERR("Main watchdog timeout install failed (%d)",
                watchdog_main_channel);
        return watchdog_main_channel;
    }

    watchdog_safety_channel = wdt_install_timeout(watchdog_dev, &timeout);
    if (watchdog_safety_channel < 0) {
        LOG_ERR("Safety watchdog timeout install failed (%d)",
                watchdog_safety_channel);
        watchdog_main_channel = -1;
        return watchdog_safety_channel;
    }

    /* WDT_OPT_PAUSE_HALTED_BY_DBG: with options=0 the nrfx driver sets
     * RUN_HALT, so the watchdog keeps counting while a debugger has the CPU
     * halted. A flash write takes far longer than the 5 s timeout, so the
     * WDT fired mid-algorithm and reset the SoC -- that is the intermittent
     * "timeout waiting for algorithm ... error writing to flash at 0xc000"
     * that left the app region half erased.
     *
     * This changes NOTHING in the field: the option only applies while a
     * debugger has halted the core, and no debugger is attached on a
     * shipped unit. Sleep behaviour is deliberately left alone (the WDT
     * still runs in sleep) so real hangs are still caught. */
    int ret = wdt_setup(watchdog_dev, WDT_OPT_PAUSE_HALTED_BY_DBG);
    if (ret < 0) {
        LOG_ERR("Watchdog setup failed (%d)", ret);
        watchdog_main_channel = -1;
        watchdog_safety_channel = -1;
        return ret;
    }

    LOG_INF("Hardware watchdog armed at %u ms (main + heater safety)",
            MAIN_WATCHDOG_TIMEOUT_MS);
    return 0;
}

static void watchdog_feed_main(void)
{
    if (watchdog_main_channel >= 0) {
        int ret = wdt_feed(watchdog_dev, watchdog_main_channel);
        if (ret < 0) {
            heater_force_off("watchdog feed failed", true);
            LOG_ERR("Watchdog feed failed (%d)", ret);
        }
    }
}

static void watchdog_feed_safety(void)
{
    if (watchdog_safety_channel >= 0) {
        int ret = wdt_feed(watchdog_dev, watchdog_safety_channel);
        if (ret < 0) {
            heater_force_off("safety watchdog feed failed", true);
            LOG_ERR("Safety watchdog feed failed (%d)", ret);
        }
    }
}

static int heater_adc_read(int16_t *sample)
{
    if (!sample || !atomic_get(&adc_ready_atomic)) {
        return -ENODEV;
    }

    struct adc_sequence sequence = {
        .buffer = sample,
        .buffer_size = sizeof(*sample),
        .resolution = 12,
        .channels = BIT(heater_adc_channel.channel_id),
    };

    k_mutex_lock(&adc_mutex, K_FOREVER);
    int ret = adc_read_dt(&heater_adc_channel, &sequence);
    k_mutex_unlock(&adc_mutex);
    return ret;
}

/*
 * Independent safety supervisor. It is intentionally cooperative and above
 * the UI/main thread, but sleeps every 50 ms so Bluetooth and system work can
 * run. Hardware access shared with the UI is serialized.
 */
static void heater_safety_thread(void *a, void *b, void *c)
{
    ARG_UNUSED(a);
    ARG_UNUSED(b);
    ARG_UNUSED(c);

    int ntc_valid_streak = 0;
    float safety_temp_c = NAN;
    float rate_window_temp_c = NAN;
    float rise_baseline_temp_c = NAN;
    int64_t rate_window_ms = 0;
    int64_t heater_started_ms = 0;
    int64_t rail_paused_ms = 0;
    int64_t next_pmic_ms = 0;
    int64_t next_tps_status_ms = 0;

    while (1) {
        int64_t now = k_uptime_get();
        watchdog_feed_safety();

        int16_t sample = 0;
        int adc_ret = heater_adc_read(&sample);
        if (adc_ret < 0 ||
            sample < NTC_RAW_VALID_MIN || sample > NTC_RAW_VALID_MAX) {
            ntc_valid_streak = 0;
            atomic_set(&ntc_valid_atomic, 0);
            safety_temp_c = NAN;
            /*
             * Product schematic (I_spoon_heater.pdf): ADC_IN is net H+,
             * the TPS heater rail, with a 10 k pull-up. With EN low the
             * ADC sits outside the NTC window, so treating that as a
             * fault deadlocked the rail OFF (app ON, no display icon).
             * Keep time-cap + 75 C when a real temperature is available.
             */
        } else {
            safety_temp_c = ntc_temp_from_raw((float)sample);
            if (!isfinite(safety_temp_c) ||
                safety_temp_c < -20.0f || safety_temp_c > 125.0f) {
                ntc_valid_streak = 0;
                atomic_set(&ntc_valid_atomic, 0);
                safety_temp_c = NAN;
            } else {
                if (ntc_valid_streak < NTC_VALID_SAMPLES_REQUIRED) {
                    ntc_valid_streak++;
                }
                if (ntc_valid_streak >= NTC_VALID_SAMPLES_REQUIRED) {
                    atomic_set(&ntc_valid_atomic, 1);
                }

                int32_t tx100 = (int32_t)lroundf(safety_temp_c * 100.0f);
                if (tx100 > INT16_MAX) {
                    tx100 = INT16_MAX;
                } else if (tx100 < INT16_MIN) {
                    tx100 = INT16_MIN;
                }
                atomic_set(&shared_temp_c100,
                           (atomic_val_t)(int16_t)tx100);

                if (safety_temp_c >= HEATER_HARD_LIMIT_C) {
                    heater_force_off("75 C hard temperature limit", true);
                }
            }
        }

        if (atomic_get(&pmic_ready_atomic) && now >= next_pmic_ms) {
            next_pmic_ms = now + PMIC_SAFETY_POLL_MS;
            (void)npm_vbat_read_mv();
        }

        if (atomic_get(&tps_rail_state) && now >= next_tps_status_ms) {
            uint8_t status = 0;
            next_tps_status_ms = now + TPS_STATUS_POLL_MS;
            int status_ret = tps_read_status(&status);

            if (status_ret < 0) {
                heater_force_off("TPS status read failed", true);
            } else if ((status & TPS_STATUS_FAULT_MASK) != 0U) {
                LOG_ERR("TPS fault status 0x%02X", status);
                heater_force_off("TPS thermal/hiccup/UVLO fault", true);
            }
        }

        if (atomic_get(&heater_on_atomic)) {
            int setpoint = (int)atomic_get(&heater_setpoint_c);
            uint16_t battery_mv =
                (uint16_t)atomic_get(&npm_cached_vbat_mv);
            uint8_t charge_status =
                (uint8_t)atomic_get(&npm_cached_charge_status);
            uint8_t vbus_status =
                (uint8_t)atomic_get(&npm_cached_vbus_status);
            bool rail_on = atomic_get(&tps_rail_state) != 0;
            bool battery_too_low =
                battery_mv < (rail_on ? HEATER_BATTERY_HARD_MIN_MV :
                                       HEATER_BATTERY_START_MIN_MV);
            bool hard_stop = !atomic_get(&bt_connected) ||
                             atomic_get(&dfu_locked_atomic) ||
                             atomic_get(&heater_fault_atomic) ||
                             ((uint8_t)atomic_get(&npm_cached_error) != 0U);
            bool pause = !atomic_get(&tps_ready_atomic) ||
                         !atomic_get(&battery_status_valid) ||
                         ((vbus_status & 0x01U) != 0U) ||
                         ((charge_status & NPM_CHGSTAT_CHARGING) != 0U) ||
                         battery_too_low;

            if (hard_stop) {
                heater_force_off("heater safety interlock", false);
            } else if (pause) {
                if (rail_on) {
                    heater_pause_rail("USB/charge/battery pause");
                    rail_paused_ms = now;
                    k_work_reschedule(&event_work, K_NO_WAIT);
                }
            } else if (setpoint > 0 && isfinite(safety_temp_c) &&
                       safety_temp_c >= (float)setpoint) {
                if (rail_on) {
                    heater_pause_rail("setpoint reached — holding");
                    rail_paused_ms = now;
                    k_work_reschedule(&event_work, K_NO_WAIT);
                }
            } else if (!rail_on) {
                bool should_heat = true;

                if (setpoint > 0 && isfinite(safety_temp_c)) {
                    should_heat = safety_temp_c <=
                        ((float)setpoint - HEATER_HYSTERESIS_C);
                }
                if (should_heat && rail_paused_ms != 0 &&
                    (now - rail_paused_ms) < (int64_t)HEATER_BURST_COOLDOWN_MS) {
                    should_heat = false;
                }
                if (should_heat) {
                    if (tps_rail_on() < 0) {
                        heater_force_off("TPS activation/verify failed", true);
                        atomic_set(&tps_ready_atomic, 0);
                    } else {
                        heater_started_ms = now;
                        rate_window_ms = now;
                        rate_window_temp_c = safety_temp_c;
                        rise_baseline_temp_c = safety_temp_c;
                        rail_paused_ms = 0;
                        k_work_reschedule(&event_work, K_NO_WAIT);
                    }
                }
            } else {
                uint32_t runtime_limit = setpoint > 0
                    ? HEATER_TARGET_MAX_MS : HEATER_NO_TARGET_MAX_MS;

                if (heater_started_ms == 0 ||
                    (now - heater_started_ms) >= runtime_limit) {
                    if (setpoint > 0) {
                        heater_pause_rail("burst cap — will resume on drop");
                        rail_paused_ms = now;
                        k_work_reschedule(&event_work, K_NO_WAIT);
                    } else {
                        heater_force_off("maximum heater runtime reached",
                                         true);
                    }
                } else if (isfinite(safety_temp_c) &&
                           isfinite(rate_window_temp_c) &&
                           (now - rate_window_ms) >= HEATER_RATE_WINDOW_MS) {
                    float elapsed_s =
                        (float)(now - rate_window_ms) / 1000.0f;
                    float rise_rate =
                        (safety_temp_c - rate_window_temp_c) / elapsed_s;

                    rate_window_ms = now;
                    rate_window_temp_c = safety_temp_c;
                    if (rise_rate > HEATER_MAX_RISE_C_PER_S) {
                        LOG_ERR("heater temperature rise %.1f C/s",
                                (double)rise_rate);
                        heater_force_off("implausible temperature rise", true);
                    }
                }

                if (atomic_get(&heater_on_atomic) &&
                    isfinite(safety_temp_c) &&
                    isfinite(rise_baseline_temp_c) &&
                    (now - heater_started_ms) >= HEATER_NO_RISE_WINDOW_MS &&
                    (safety_temp_c - rise_baseline_temp_c) <
                        HEATER_MIN_RISE_C) {
                    heater_force_off("heater produced no temperature rise",
                                     true);
                }
            }
        } else {
            if (atomic_get(&tps_rail_state)) {
                (void)tps_rail_off();
            }
            heater_started_ms = 0;
            rate_window_ms = 0;
            rail_paused_ms = 0;
            rate_window_temp_c = NAN;
            rise_baseline_temp_c = NAN;
        }

        k_msleep(HEATER_SAFETY_PERIOD_MS);
    }
}

K_THREAD_STACK_DEFINE(heater_safety_stack, HEATER_SAFETY_STACK_SIZE);
static struct k_thread heater_safety_thread_data;

static int heater_safety_start(void)
{
    k_tid_t tid = k_thread_create(&heater_safety_thread_data,
                                  heater_safety_stack,
                                  K_THREAD_STACK_SIZEOF(heater_safety_stack),
                                  heater_safety_thread,
                                  NULL, NULL, NULL,
                                  HEATER_SAFETY_PRIORITY, 0, K_NO_WAIT);
    if (!tid) {
        return -EIO;
    }
    (void)k_thread_name_set(tid, "heater_safety");
    return 0;
}

/* ============================================================
 * ================= DATA PATH: IMU -> BLE ====================
 * ============================================================
 *
 * Producer/consumer split (v1 sent notifications from inside the
 * sampling loop, so a slow BLE send stalled sampling and silently
 * lowered the effective sample rate):
 *
 *   imu_thread  (prio 6)  : samples BMI270 at exactly 100 Hz, batches
 *                           10 samples, builds the 129 B packet, puts
 *                           it on tx_msgq. NEVER blocks on BLE.
 *   ble_tx_thread (prio 7): blocking-reads tx_msgq and calls
 *                           bt_gatt_notify with retry/backoff. All BLE
 *                           latency is absorbed here.
 *
 *   tx_msgq depth 4 = 400 ms of buffering. If the link stalls longer
 *   (phone in a dead zone), the OLDEST packet is dropped and a drop
 *   counter increments — bounded memory, newest data wins.
 */

/* --- TX queue + thread --- */

K_MSGQ_DEFINE(tx_msgq, BULK_PKT_BYTES, 4, 4);

static atomic_t tx_dropped_total = ATOMIC_INIT(0);

#define BLE_TX_THREAD_STACK  1536
#define BLE_TX_THREAD_PRIO   7

static void ble_tx_thread(void *a, void *b, void *c)
{
    ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);

    uint8_t pkt[BULK_PKT_BYTES];
    int64_t last_mtu_warn_ms = 0;

    while (1) {
        /* Block until the IMU thread queues a packet. */
        k_msgq_get(&tx_msgq, pkt, K_FOREVER);

        if (!atomic_get(&bt_connected) ||
            !atomic_get(&ccc_wants_notify) ||
            !atomic_get(&notify_enabled)) {
            continue;               /* disconnected or CCC off */
        }

        struct bt_conn *conn = conn_acquire();
        if (!conn) {
            continue;               /* disconnected mid-flight */
        }

        /* Resync L2 flag for identity / encrypted ATT. Heater uses bt_connected. */
        if (bt_conn_get_security(conn) >= BT_SECURITY_L2) {
            atomic_set(&ble_secured, 1);
        }

        uint16_t mtu = bt_gatt_get_mtu(conn);
        uint16_t max_payload = (mtu > 3U) ? (uint16_t)(mtu - 3U) : 0U;
        uint16_t send_len = BULK_PKT_BYTES;

        if (max_payload < 9U) {
            int64_t now = k_uptime_get();
            if (now - last_mtu_warn_ms > 5000) {
                last_mtu_warn_ms = now;
                LOG_WRN("MTU %u too small for any payload", mtu);
            }
            (void)bt_gatt_exchange_mtu(conn, &mtu_exchange_params);
            bt_conn_unref(conn);
            continue;
        }

        if (max_payload < BULK_PKT_BYTES) {
            /*
             * Full 129 B needs MTU >= 132. Until central accepts MTU, send a
             * 9-byte header heartbeat so nRF Connect shows live notifies.
             * Product apps only parse exact 129 B frames.
             */
            int64_t now = k_uptime_get();
            if (now - last_mtu_warn_ms > 5000) {
                last_mtu_warn_ms = now;
                LOG_WRN("MTU %u < %u — header heartbeat until MTU grows",
                        mtu, BULK_PKT_BYTES + 3);
            }
            (void)bt_gatt_exchange_mtu(conn, &mtu_exchange_params);
            send_len = 9;
        }

        int err = -EAGAIN;
        for (int attempt = 0; attempt < 3; attempt++) {
            err = bt_gatt_notify(conn, &bc_svc.attrs[BC_TX_ATTR_INDEX],
                                 pkt, send_len);
            if (err != -EAGAIN && err != -ENOMEM) {
                break;
            }
            k_msleep(10);
        }

        if (err) {
            uint32_t n = (uint32_t)atomic_inc(&tx_dropped_total) + 1;
            if ((n % 50) == 1) {
                LOG_WRN("notify failed (%d), %u packets dropped total",
                        err, n);
            }
        }

        bt_conn_unref(conn);
    }
}

K_THREAD_DEFINE(ble_tx_tid, BLE_TX_THREAD_STACK,
                ble_tx_thread, NULL, NULL, NULL,
                BLE_TX_THREAD_PRIO, 0, 0);

/* --- IMU sampling thread ---
 *
 * Sole owner of BMI270 sensor_sample_fetch/get. Always samples at 100 Hz
 * while the spoon is ON (bite detection). BLE batch notify only when the
 * phone is bonded and subscribed. */

#define IMU_THREAD_STACK     2048
#define IMU_THREAD_PRIO      6
#define IMU_PERIOD_MS        10          /* 100 Hz — matches BMI270 ODR */
#define IMU_IDLE_POLL_MS     100

static atomic_t imu_thread_enabled = ATOMIC_INIT(0);
/* Set from main when BMI270 is ready — bite runs only on imu_thread. */
static atomic_t bite_run_atomic     = ATOMIC_INIT(0);

/* Implemented with the bite state machine (below). */
static void bite_step_eng(const struct imu_eng *s);

/*
 * Double firm handle taps (BMI270) → power-off gesture.
 * Works when assembly pressure holds the TTP223 permanently HIGH so
 * capacitive edges never appear. Tuned above typical eating motion.
 */
static void knock_step_eng(const struct imu_eng *s)
{
	static int state; /* 0 = idle, 1 = inside peak */
	static int64_t peak_start;
	static int taps;
	static int64_t last_tap_up;
	static int64_t cool_until;
	int64_t now = k_uptime_get();
	float mag = sqrtf(s->ax_g * s->ax_g + s->ay_g * s->ay_g +
			  s->az_g * s->az_g);

	if (cool_until != 0 && now < cool_until) {
		state = 0;
		taps = 0;
		return;
	}
	cool_until = 0;

	if (taps == 1 && last_tap_up != 0 &&
	    (now - last_tap_up) > KNOCK_GAP_MAX_MS) {
		taps = 0;
		last_tap_up = 0;
	}

	if (state == 0) {
		if (mag >= KNOCK_ON_G) {
			state = 1;
			peak_start = now;
		}
		return;
	}

	/* In peak: end when |a| falls, or abort if stuck high too long. */
	if (mag >= KNOCK_OFF_G) {
		if ((now - peak_start) > KNOCK_MAX_MS) {
			state = 0; /* continuous shake / not a tap */
		}
		return;
	}

	int64_t dur = now - peak_start;

	state = 0;
	if (dur < KNOCK_MIN_MS || dur > KNOCK_MAX_MS) {
		return;
	}

	if (taps == 1 && last_tap_up != 0 &&
	    (now - last_tap_up) < KNOCK_GAP_MIN_MS) {
		taps = 0;
		last_tap_up = 0;
		return;
	}

	taps++;
	last_tap_up = now;
	if (taps >= 2) {
		taps = 0;
		last_tap_up = 0;
		cool_until = now + KNOCK_COOLDOWN_MS;
		atomic_set(&knock_double_event, 1);
		LOG_INF("IMU double-knock power gesture");
	}
}

static void imu_thread(void *a, void *b, void *c)
{
    ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);

    imu_sample_t batch[IMU_SAMPLES_PER_PKT];
    int      batch_idx = 0;
    uint32_t batch_ts0 = 0;
    int64_t  next_tick = k_uptime_get();

    while (1) {
        if (!atomic_get(&imu_thread_enabled)) {
            k_msleep(IMU_IDLE_POLL_MS);
            next_tick = k_uptime_get();
            batch_idx = 0;
            continue;
        }

        struct imu_eng eng;
        int ret = bmi270_read(&eng);
        imu_sample_t wire;

        if (ret == 0) {
            atomic_inc(&imu_sample_ok_count);
            atomic_set(&imu_sample_err_count, 0);
            atomic_set(&imu_healthy_atomic, 1);

            /* Always run knock detector while IMU is live (OFF gesture). */
            knock_step_eng(&eng);

            if (atomic_get(&bite_run_atomic)) {
                bite_step_eng(&eng);
            }

            imu_eng_to_pkt(&eng, &wire);
            atomic_set(&imu_last_ax_mg, (atomic_val_t)wire.ax);
            atomic_set(&imu_last_ay_mg, (atomic_val_t)wire.ay);
            atomic_set(&imu_last_az_mg, (atomic_val_t)wire.az);
        } else {
            /* IMU read failed — still stream batt/temp/timestamp so BLE path
             * can be verified in nRF Connect (last motion samples). */
            uint32_t fails =
                (uint32_t)atomic_inc(&imu_sample_err_count) + 1U;
            if (fails >= IMU_FAIL_STREAK_UNHEALTHY) {
                atomic_set(&imu_healthy_atomic, 0);
            }
            memset(&wire, 0, sizeof(wire));
            wire.ax = (int16_t)atomic_get(&imu_last_ax_mg);
            wire.ay = (int16_t)atomic_get(&imu_last_ay_mg);
            wire.az = (int16_t)atomic_get(&imu_last_az_mg);
        }

        /* Stream as soon as CCC is on — do not wait for LESC (nRF Connect). */
        if (atomic_get(&ccc_wants_notify) &&
            atomic_get(&bt_connected) &&
            atomic_get(&notify_enabled)) {
            if (batch_idx == 0) {
                batch_ts0 = k_uptime_get_32();
            }
            batch[batch_idx++] = wire;

            if (batch_idx >= IMU_SAMPLES_PER_PKT) {
                batch_idx = 0;

                uint8_t pkt[BULK_PKT_BYTES];
                uint8_t  batt  = (uint8_t)atomic_get(&shared_battery_pct);
                int16_t  t100  = (int16_t)atomic_get(&shared_temp_c100);
                uint16_t bites = (uint16_t)atomic_get(&shared_bite_count);

                int o = 0;
                pkt[o++] = batt;
                pkt[o++] = (uint8_t)(t100);
                pkt[o++] = (uint8_t)(t100 >> 8);
                pkt[o++] = (uint8_t)(batch_ts0);
                pkt[o++] = (uint8_t)(batch_ts0 >> 8);
                pkt[o++] = (uint8_t)(batch_ts0 >> 16);
                pkt[o++] = (uint8_t)(batch_ts0 >> 24);
                pkt[o++] = (uint8_t)(bites);
                pkt[o++] = (uint8_t)(bites >> 8);
                memcpy(&pkt[o], batch, sizeof(batch));

                if (k_msgq_put(&tx_msgq, pkt, K_NO_WAIT) != 0) {
                    uint8_t scratch[BULK_PKT_BYTES];
                    k_msgq_get(&tx_msgq, scratch, K_NO_WAIT);
                    k_msgq_put(&tx_msgq, pkt, K_NO_WAIT);
                    atomic_inc(&tx_dropped_total);
                }
            }
        } else {
            batch_idx = 0;
        }

        next_tick += IMU_PERIOD_MS;
        int64_t wait = next_tick - k_uptime_get();
        if (wait > 0) {
            k_msleep((uint32_t)wait);
        } else {
            next_tick = k_uptime_get();
        }
    }
}

K_THREAD_DEFINE(imu_tid, IMU_THREAD_STACK,
                imu_thread, NULL, NULL, NULL,
                IMU_THREAD_PRIO, 0, 0);

/* ================= BITE-COUNTER STATE MACHINE ================= */

enum BitePhase { BP_RESTING, BP_LIFTING, BP_RETURNING };

/* ── Adaptive, position-independent bite thresholds (mirror the app's
 *    imu_bite_detector_service.dart). All movement gates are RELATIVE to a
 *    dynamic baseline, so they hold at any spoon orientation / eating posture. */

/* Gyro magnitude (deg/s) above which the spoon is "actively moving" — starts a
 * lift excursion. Below BITE_GYRO_STILL_DPS it is "still" (baseline capture). */
static const float BITE_GYRO_MOVE_DPS  = 30.0f;
static const float BITE_GYRO_STILL_DPS = 15.0f;

/* Minimum orientation change from the rest baseline (g; ~1g ≈ 90° tilt) for an
 * excursion to qualify as a real lift-to-mouth. ~0.30g ≈ 17–18°. Filters out
 * scooping wiggles and small nudges. */
static const float BITE_MIN_PEAK_DEV_G = 0.30f;

/* Minimum integrated rotation (deg) over the cycle — the "distance travelled"
 * gate. A genuine lift + return rotates the spoon meaningfully. */
static const float BITE_MIN_TRAVEL_DEG = 35.0f;

/* Past the apex once deviation drops below this fraction of the peak. */
static const float BITE_RETURN_FRAC = 0.45f;

/* Deviation (g) below which the spoon is back near rest — completes the cycle. */
static const float BITE_SETTLE_DEV_G = 0.18f;

/* Low-pass time constant (s) for the gravity/orientation estimate, and the
 * gentle rate at which the rest baseline tracks true rest. */
static const float BITE_GRAVITY_TAU_S = 0.12f;
static const float BITE_REST_BETA     = 0.08f;

/* Cycle timing gates + refractory cooldown between counted bites (ms). A cycle
 * faster than MIN is a flick/noise; slower than MAX is aborted (spoon set down
 * mid-air). Small-distance lifts still count as long as travel + shape pass. */
static const uint32_t BITE_MIN_CYCLE_MS    = 350;
static const uint32_t BITE_MAX_CYCLE_MS    = 9000;
static const uint32_t BITE_COOLDOWN_MS     = 1400;
static const uint32_t BITE_REST_CAPTURE_MS = 250;

typedef struct {
    enum BitePhase phase;

    /* Gravity/orientation estimate (low-passed accel) and the captured rest
     * baseline the current excursion is measured against. */
    float gEx, gEy, gEz;
    float restX, restY, restZ;
    bool  initialized;

    uint32_t prevTsMs;
    float    stillMs;

    /* Per-excursion tracking. */
    uint32_t excursionStartMs;
    float    peakDev;
    float    travelDeg;

    uint32_t lastBiteMs;
    int      biteCount;
} bite_t;

static bite_t bite;

/* Euclidean distance between two 3-vectors — the orientation-change magnitude
 * (g) of the current gravity estimate from the rest baseline. */
static float bite_vec_dist(float ax, float ay, float az,
                           float bx, float by, float bz)
{
    float dx = ax - bx, dy = ay - by, dz = az - bz;
    return sqrtf(dx * dx + dy * dy + dz * dz);
}

static void bite_reset(void)
{
    memset(&bite, 0, sizeof(bite));
    bite.phase = BP_RESTING;
    /* Sane defaults before the first sample bootstraps the real estimate. */
    bite.gEz   = 1.0f;
    bite.restZ = 1.0f;
}

/* Adaptive kinematic bite detector — engineering units (g, deg/s), called only
 * from imu_thread. Orientation-independent: measures each lift as the change in
 * the gravity vector from a DYNAMIC rest baseline (captured wherever the spoon
 * is held while scooping), and requires a complete rest → lift → apex → return
 * → rest cycle, validated by integrated rotation ("distance travelled") and
 * cycle timing with a refractory cooldown. Small-distance lifts still count as
 * long as the travel + shape + cooldown gates pass, which is what kills false
 * bites while staying accurate at any posture. */
static void bite_step_eng(const struct imu_eng *s)
{
    float ax = s->ax_g, ay = s->ay_g, az = s->az_g;
    float gyro = sqrtf(s->gx_dps * s->gx_dps +
                       s->gy_dps * s->gy_dps +
                       s->gz_dps * s->gz_dps);
    uint32_t ts = k_uptime_get_32();

    /* Bootstrap gravity estimate + rest baseline on the first sample. */
    if (!bite.initialized) {
        bite.gEx = ax; bite.gEy = ay; bite.gEz = az;
        bite.restX = ax; bite.restY = ay; bite.restZ = az;
        bite.prevTsMs = ts;
        bite.initialized = true;
        return;
    }

    /* Rate-agnostic dt (s), clamped so a sensor/BLE stall cannot distort the
     * rotation integral. */
    float dt = (float)(ts - bite.prevTsMs) / 1000.0f;
    bite.prevTsMs = ts;
    if (dt <= 0.0f) return;
    if (dt > 0.1f) dt = 0.1f;

    /* Time-constant low-pass → gravity/orientation estimate (removes tremor and
     * transient linear-accel spikes so `dev` is a true tilt-change measure). */
    float a = dt / (BITE_GRAVITY_TAU_S + dt);
    bite.gEx += a * (ax - bite.gEx);
    bite.gEy += a * (ay - bite.gEy);
    bite.gEz += a * (az - bite.gEz);

    float dev = bite_vec_dist(bite.gEx, bite.gEy, bite.gEz,
                              bite.restX, bite.restY, bite.restZ);
    bool still = gyro < BITE_GYRO_STILL_DPS;

    switch (bite.phase) {
    case BP_RESTING:
        if (still) {
            /* Continuously refresh the rest baseline toward the current
             * orientation once still long enough — this is what makes the
             * detector adapt to ANY eating posture / hold angle. */
            bite.stillMs += dt * 1000.0f;
            if (bite.stillMs >= (float)BITE_REST_CAPTURE_MS) {
                bite.restX += BITE_REST_BETA * (bite.gEx - bite.restX);
                bite.restY += BITE_REST_BETA * (bite.gEy - bite.restY);
                bite.restZ += BITE_REST_BETA * (bite.gEz - bite.restZ);
            }
        } else {
            bite.stillMs = 0.0f;
            /* Start of a lift: active rotation AND orientation departing rest. */
            if (gyro > BITE_GYRO_MOVE_DPS && dev > BITE_MIN_PEAK_DEV_G * 0.4f) {
                bite.phase = BP_LIFTING;
                bite.excursionStartMs = ts;
                bite.peakDev = dev;
                bite.travelDeg = gyro * dt;
            }
        }
        break;

    case BP_LIFTING:
    case BP_RETURNING: {
        bite.travelDeg += gyro * dt;        /* integrate rotation = "distance" */
        if (dev > bite.peakDev) bite.peakDev = dev;
        uint32_t elapsed = ts - bite.excursionStartMs;

        /* Abort an excursion that never comes back (spoon set down mid-air, or a
         * one-way orientation change that isn't a bite). */
        if (elapsed > BITE_MAX_CYCLE_MS) {
            bite.restX = bite.gEx; bite.restY = bite.gEy; bite.restZ = bite.gEz;
            bite.stillMs = 0.0f;
            bite.phase = BP_RESTING;
            break;
        }

        /* Past the apex and heading back toward rest. */
        if (bite.phase == BP_LIFTING &&
            bite.peakDev >= BITE_MIN_PEAK_DEV_G &&
            dev < BITE_RETURN_FRAC * bite.peakDev) {
            bite.phase = BP_RETURNING;
        }

        /* Cycle completes when we are back near the rest baseline. */
        if (dev < BITE_SETTLE_DEV_G && (bite.phase == BP_RETURNING || still)) {
            bool valid =
                bite.peakDev >= BITE_MIN_PEAK_DEV_G &&
                bite.travelDeg >= BITE_MIN_TRAVEL_DEG &&
                elapsed >= BITE_MIN_CYCLE_MS &&
                elapsed <= BITE_MAX_CYCLE_MS &&
                (bite.lastBiteMs == 0 ||
                 (ts - bite.lastBiteMs) >= BITE_COOLDOWN_MS);
            if (valid) {
                bite.biteCount++;
                atomic_set(&shared_bite_count,
                           (atomic_val_t)(uint16_t)bite.biteCount);
                bite.lastBiteMs = ts;
            }
            /* Re-anchor the rest baseline to where the spoon actually settled. */
            bite.restX = bite.gEx; bite.restY = bite.gEy; bite.restZ = bite.gEz;
            bite.stillMs = 0.0f;
            bite.phase = BP_RESTING;
        }
        break;
    }
    }
}

/* ================= STATUS BAR ================= */
/*
 * Laid out inside the CAD window (22.70 × 10.00 mm, R4.00). All glyphs stay
 * in UI_SAFE_* so the rounded opening does not clip them.
 *
 *   safe 12                                                  147
 *   [ BT+waves ] [HEAT]                    [⚡][ 85%][BATT]
 */

#define STATUS_Y       UI_SAFE_Y0
#define STATUS_BAR_H   16
#define STATUS_RIGHT_X UI_SAFE_X1
#define STATUS_LEFT_X  UI_SAFE_X0

#define TEMP_HEADER_Y  (STATUS_Y + STATUS_BAR_H + 4)
#define TEMP_VALUE_Y   (TEMP_HEADER_Y + BIG_CELL_H + 4)

/* Bluetooth rune + radio waves, left cluster. */
#define STATUS_BT_SLOT_W  BT_ICON_W
#define STATUS_BT_X       STATUS_LEFT_X
#define STATUS_BT_Y       STATUS_Y

/* Right cluster (right → left): battery icon | percent | charging bolt */
#define STATUS_BAT_X   (STATUS_RIGHT_X - BAT_ICON_W)

#define STATUS_PCT_W   (4 * SMALL_CELL_W)
#define STATUS_PCT_X1  (STATUS_BAT_X - 2)
#define STATUS_PCT_X0  (STATUS_PCT_X1 - STATUS_PCT_W)
#define STATUS_PCT_Y   (STATUS_Y + (BAT_ICON_H - SMALL_CELL_H) / 2)

#define STATUS_BOLT_X  (STATUS_PCT_X0 - 2 - BOLT_W)
#define STATUS_BOLT_Y  STATUS_Y

/* Heater sits just right of the BT mark, far clear of the battery cluster. */
#define STATUS_HEATER_X   (STATUS_BT_X + STATUS_BT_SLOT_W + 4)
#define STATUS_HEATER_Y   STATUS_Y

/* Fail the build rather than silently overlapping if anything grows. */
BUILD_ASSERT(STATUS_BT_X + STATUS_BT_SLOT_W < STATUS_HEATER_X,
             "status bar: BT badge would overlap the heater icon");
BUILD_ASSERT(STATUS_HEATER_X + HEATER_ICON_W < STATUS_BOLT_X,
             "status bar: left cluster would overlap the battery cluster");
BUILD_ASSERT(STATUS_BAT_X + BAT_ICON_W <= UI_SAFE_X1,
             "status bar: battery icon would leave the R4 window");
BUILD_ASSERT(STATUS_BT_X >= UI_SAFE_X0,
             "status bar: BT mark would sit in the left fillet");
BUILD_ASSERT(TEMP_VALUE_Y + BIG_CELL_H <= UI_SAFE_Y1,
             "TEMP value would sit in the bottom fillet");

static int  status_fill_cached     = -1;
static int  status_color_cached    = -1;
static int  status_pct_cached      = -1;      /* numeric percent shown */
static bool status_bt_cached       = false;
static bool status_heater_cached   = false;
static bool status_charging_cached = false;
static bool status_initialised     = false;

#define BLINK_PERIOD_MS    1000
#define BLINK_DUTY_MS       500
static bool status_bolt_visible    = true;

static uint16_t batt_icon_color(uint8_t pct, bool charging)
{
    if (charging)            return COLOR_GREEN;
    if (pct <= BATT_LOW_PCT) return COLOR_RED;
    return COLOR_FG;
}

static void status_draw_battery(uint8_t pct, bool charging)
{
    draw_battery_icon(STATUS_BAT_X, STATUS_Y, pct,
                      batt_icon_color(pct, charging));
}

/* Draw the percent number RIGHT-aligned against the battery icon, in the same
 * color as the icon (white / red / green).
 *
 * Right-aligned because the cluster hugs the right edge: the number must sit
 * flush against the icon it belongs to, growing leftwards as it gets longer.
 * The full 4-char strip is erased first, so shrinking strings ("100%" -> "9%")
 * never leave stale glyphs behind. */
static void status_draw_pct(uint8_t pct, bool charging)
{
    uint16_t color = batt_icon_color(pct, charging);

    fill_rect(STATUS_PCT_X0, STATUS_PCT_Y, STATUS_PCT_W, SMALL_CELL_H,
              COLOR_BG);

    char buf[6];
    int len = snprintf(buf, sizeof(buf), "%u%%", (unsigned)pct);
    if (len < 0) return;
    if (len > 4) len = 4;   /* clamp so right-align can never run left of X0 */

    draw_text_small_at(STATUS_PCT_X1 - len * SMALL_CELL_W, STATUS_PCT_Y,
                       buf, color, COLOR_BG);
}

static void status_draw_bt(bool show)
{
	fill_rect(STATUS_BT_X, STATUS_BT_Y, STATUS_BT_SLOT_W, BT_ICON_H,
		  COLOR_BG);

	if (!show) {
		return;
	}

	/* Product Bluetooth mark (rune + radio waves), not the letters "BT". */
	draw_bt_icon(STATUS_BT_X, STATUS_BT_Y, COLOR_BT);
}

static void status_draw_heater(bool show)
{
    fill_rect(STATUS_HEATER_X, STATUS_HEATER_Y, HEATER_ICON_W, HEATER_ICON_H,
              COLOR_BG);
    if (show) {
        draw_heater_icon(STATUS_HEATER_X, STATUS_HEATER_Y);
    }
}

static void status_draw_bolt(bool show)
{
    fill_rect(STATUS_BOLT_X, STATUS_BOLT_Y, BOLT_W, BOLT_H, COLOR_BG);
    if (show) {
        draw_bolt_icon(STATUS_BOLT_X, STATUS_BOLT_Y, COLOR_GREEN);
    }
}

static void status_force_redraw(uint8_t pct, bool bt_on, bool heater_on,
                                bool charging)
{
    status_fill_cached     = bat_fill_pixels(pct);
    status_color_cached    = (int)batt_icon_color(pct, charging);
    status_pct_cached      = pct;
    status_bt_cached       = bt_on;
    status_heater_cached   = heater_on;
    status_charging_cached = charging;
    status_initialised     = true;
    status_bolt_visible    = charging;

    status_draw_battery(pct, charging);
    status_draw_pct(pct, charging);
    status_draw_bt(bt_on);
    status_draw_heater(heater_on);
    status_draw_bolt(charging);
}

static void status_update(uint8_t pct, bool bt_on, bool heater_on,
                          bool charging)
{
    if (!status_initialised) {
        status_force_redraw(pct, bt_on, heater_on, charging);
        return;
    }

    int  fill        = bat_fill_pixels(pct);
    int  color       = (int)batt_icon_color(pct, charging);
    bool bat_changed = (fill != status_fill_cached) ||
                       (color != status_color_cached);
    /* The text changes on EVERY 1% step (unlike the 20-px fill bar),
     * and also whenever the color flips (low / charging). */
    bool pct_changed = ((int)pct != status_pct_cached) ||
                       (color != status_color_cached);
    bool bt_changed     = (bt_on != status_bt_cached);
    bool heater_changed = (heater_on != status_heater_cached);
    bool chg_changed    = (charging != status_charging_cached);

    if (bat_changed) {
        status_draw_battery(pct, charging);
        status_fill_cached  = fill;
    }
    if (pct_changed) {
        status_draw_pct(pct, charging);
        status_pct_cached = pct;
    }
    if (bat_changed || pct_changed) {
        status_color_cached = color;
    }
    if (chg_changed) {
        status_draw_bolt(charging);
        status_charging_cached = charging;
        status_bolt_visible    = charging;
    }
    /*
     * Repaint ONLY on transition — like every other indicator here.
     *
     * This used to be `if (bt_changed || bt_on)`, i.e. an unconditional repaint
     * on every status update while connected. Since status_draw_bt() erases to
     * background before painting the pill, that produced a black→green→text
     * cycle on each refresh: a visible flicker for as long as the phone stayed
     * linked.
     *
     * The unconditional repaint was defending the badge against the centred
     * TEMP header redrawing over it. The mark now lives in the left safe
     * inset, clear of TEMP, so change-gating is flicker-free.
     */
    if (bt_changed) {
        if (bt_on) {
            LOG_INF("UI: BLE connected — BT mark @x=%d", STATUS_BT_X);
        } else {
            LOG_INF("UI: BLE disconnected — BT badge OFF");
        }
        status_draw_bt(bt_on);
        status_bt_cached = bt_on;
    }
    if (heater_changed) {
        status_draw_heater(heater_on);
        status_heater_cached = heater_on;
    }
}

static void status_invalidate(void)
{
    status_initialised     = false;
    status_fill_cached     = -1;
    status_color_cached    = -1;
    status_pct_cached      = -1;
    status_bt_cached       = false;
    status_heater_cached   = false;
    status_charging_cached = false;
    status_bolt_visible    = true;
}

static void status_tick_blink(bool charging)
{
    /* Solid bolt while USB is present. A 1 Hz blink looked like the
     * device was connecting/disconnecting while charging. */
    if (!status_initialised) {
        return;
    }
    if (!charging) {
        if (status_bolt_visible) {
            status_bolt_visible = false;
            status_draw_bolt(false);
        }
        return;
    }
    if (!status_bolt_visible) {
        status_bolt_visible = true;
        status_draw_bolt(true);
    }
}

/* ================= PMIC DEBUG SCREEN ================= */

#define PMIC_DBG_Y0          (UI_SAFE_Y0 + 12)
#define PMIC_DBG_LINE_H      10
#define PMIC_DBG_LABEL_X     UI_SAFE_X0
#define PMIC_DBG_VALUE_X     (UI_SAFE_X0 + 5 * SMALL_CELL_W + 4)

#if PMIC_DEBUG_VIEW
static char nybble_to_hex(uint8_t n)
{
    n &= 0x0F;
    return (n < 10) ? ('0' + n) : ('A' + n - 10);
}

static void byte_to_hex(uint8_t b, char *buf)
{
    buf[0] = nybble_to_hex(b >> 4);
    buf[1] = nybble_to_hex(b & 0x0F);
}

static void pmic_debug_init_screen(void)
{
    fill_color(COLOR_BG);

    draw_text_small_at(PMIC_DBG_LABEL_X, PMIC_DBG_Y0 + 0 * PMIC_DBG_LINE_H,
                       "VBUS:", COLOR_FG, COLOR_BG);
    draw_text_small_at(PMIC_DBG_LABEL_X, PMIC_DBG_Y0 + 1 * PMIC_DBG_LINE_H,
                       "STAT:", COLOR_FG, COLOR_BG);
    draw_text_small_at(PMIC_DBG_LABEL_X, PMIC_DBG_Y0 + 2 * PMIC_DBG_LINE_H,
                       "ERR :", COLOR_FG, COLOR_BG);
    draw_text_small_at(PMIC_DBG_LABEL_X, PMIC_DBG_Y0 + 3 * PMIC_DBG_LINE_H,
                       "SENS:", COLOR_FG, COLOR_BG);
    draw_text_small_at(PMIC_DBG_LABEL_X, PMIC_DBG_Y0 + 4 * PMIC_DBG_LINE_H,
                       "ICHG:", COLOR_FG, COLOR_BG);
}

static void pmic_debug_draw_line(int line, uint8_t hex_byte, const char *suffix)
{
    int y = PMIC_DBG_Y0 + line * PMIC_DBG_LINE_H;

    fill_rect(PMIC_DBG_VALUE_X, y,
              TFT_VISIBLE_W - PMIC_DBG_VALUE_X, SMALL_CELL_H, COLOR_BG);

    char buf[24];
    byte_to_hex(hex_byte, buf);
    buf[2] = ' ';
    int n = 3;
    if (suffix) {
        for (int i = 0; suffix[i] && n < (int)sizeof(buf) - 1; i++) {
            buf[n++] = suffix[i];
        }
    }
    buf[n] = 0;

    draw_text_small_at(PMIC_DBG_VALUE_X, y, buf, COLOR_FG, COLOR_BG);
}

static void decode_chgstat(uint8_t s, char *out5)
{
    out5[0] = (s & NPM_CHGSTAT_BATTDET)  ? 'B' : '-';
    out5[1] = (s & NPM_CHGSTAT_COMPLETE) ? 'F' : '-';
    out5[2] = (s & NPM_CHGSTAT_TRICKLE)  ? 'T' : '-';
    out5[3] = (s & NPM_CHGSTAT_CC)       ? 'C' : '-';
    out5[4] = (s & NPM_CHGSTAT_CV)       ? 'V' : '-';
    out5[5] = 0;
}

static void pmic_debug_update(void)
{
    uint8_t vbus_stat = 0, chg_stat = 0;
    uint8_t err_reason = 0, err_sensor = 0;
    uint8_t ichg = 0;

    i2c_reg_read8(NPM_ADDR, NPM_BASE_VBUS, NPM_REG_VBUSINSTATUS,    &vbus_stat);
    i2c_reg_read8(NPM_ADDR, NPM_BASE_CHG,  NPM_REG_BCHGCHARGESTATUS, &chg_stat);
    i2c_reg_read8(NPM_ADDR, NPM_BASE_CHG,  NPM_REG_BCHGERRREASON,    &err_reason);
    i2c_reg_read8(NPM_ADDR, NPM_BASE_CHG,  NPM_REG_BCHGERRSENSOR,    &err_sensor);
    i2c_reg_read8(NPM_ADDR, NPM_BASE_CHG,  NPM_REG_BCHGISET,         &ichg);

    pmic_debug_draw_line(0, vbus_stat,  (vbus_stat & 0x01) ? "USB" : "---");

    char chg_letters[6];
    decode_chgstat(chg_stat, chg_letters);
    pmic_debug_draw_line(1, chg_stat, chg_letters);

    pmic_debug_draw_line(2, err_reason,  (err_reason  != 0) ? "FAULT" : "OK");
    pmic_debug_draw_line(3, err_sensor,  NULL);

    char ichg_buf[12];
    byte_to_hex(ichg, ichg_buf);
    ichg_buf[2] = 0;
    int yy = PMIC_DBG_Y0 + 4 * PMIC_DBG_LINE_H;
    fill_rect(PMIC_DBG_VALUE_X, yy,
              TFT_VISIBLE_W - PMIC_DBG_VALUE_X, SMALL_CELL_H, COLOR_BG);
    draw_text_small_at(PMIC_DBG_VALUE_X, yy, ichg_buf, COLOR_FG, COLOR_BG);
}
#endif /* PMIC_DEBUG_VIEW */

/* ================= UI ================= */

typedef enum { UI_BLANK, UI_SPLASH, UI_TEMP } ui_state_t;
static ui_state_t ui = UI_BLANK;

static void show_splash_animated(void)
{
    /* Big font is uppercase-only ('o' is degree). Two lines fit 160 px. */
    static const char line1[] = "ISPOON";
    static const char line2[] = "PRO";
    int len1 = (int)strlen(line1);
    int len2 = (int)strlen(line2);
    int x1 = (TFT_VISIBLE_W - (len1 * BIG_CELL_W)) / 2;
    int x2 = (TFT_VISIBLE_W - (len2 * BIG_CELL_W)) / 2;
    if (x1 < 0) x1 = 0;
    if (x2 < 0) x2 = 0;
    int y1 = UI_SAFE_Y0 + 8;
    int y2 = y1 + BIG_CELL_H + 4;
    fill_color(COLOR_BG);
    for (int i = 0; i < len1; i++) {
        draw_char_big(x1 + i * BIG_CELL_W, y1, line1[i], COLOR_FG, COLOR_BG);
        watchdog_feed_main();
        k_msleep(LETTER_STEP_MS);
    }
    for (int i = 0; i < len2; i++) {
        draw_char_big(x2 + i * BIG_CELL_W, y2, line2[i], COLOR_FG, COLOR_BG);
        watchdog_feed_main();
        k_msleep(LETTER_STEP_MS);
    }
}

/* last_temp sentinel: display is showing "-- oC" (NTC not connected). */
#define TEMP_DISPLAY_INVALID   (INT_MIN + 1)

/* Fixed 5-char temperature field: "-- oC" or "25 oC" / "-9 oC". */
static void temp_format_5(int t_int, char buf5[6])
{
	if (t_int == TEMP_DISPLAY_INVALID) {
		memcpy(buf5, "-- oC", 5);
		buf5[5] = 0;
		return;
	}
	/* Clamp to fit 5 glyphs with degree 'o' + 'C'. */
	if (t_int < -9) {
		t_int = -9;
	}
	if (t_int > 99) {
		t_int = 99;
	}
	if (t_int < 0) {
		/* "-9 oC" */
		snprintf(buf5, 6, "%d oC", t_int);
	} else {
		/* " 5 oC" / "25 oC" — always 5 chars */
		snprintf(buf5, 6, "%2d oC", t_int);
	}
	buf5[5] = 0;
}

static void temp_draw_value(int val_x, int t_int, char *prev_buf)
{
	char buf[6];

	temp_format_5(t_int, buf);
	for (int i = 0; i < 5; i++) {
		if (buf[i] != prev_buf[i]) {
			draw_char_big(val_x + i * BIG_CELL_W,
				      TEMP_VALUE_Y,
				      buf[i], COLOR_FG, COLOR_BG);
			prev_buf[i] = buf[i];
		}
	}
}

/* Force every glyph/status pixel (used on layout entry + periodic refresh). */
static void temp_draw_value_force(int val_x, int t_int, char *prev_buf)
{
	memset(prev_buf, 0, 5);
	prev_buf[5] = 0;
	temp_draw_value(val_x, t_int, prev_buf);
}

static int show_temp_layout(void)
{
	/*
	 * Double-clear GRAM so ISPOON PRO never leaves ghosts mixed with TEMP.
	 * Single fill was not always enough on some panels / offsets.
	 */
	fill_color(COLOR_BG);
	fill_color(COLOR_BG);

	draw_text_big_center("TEMP", TEMP_HEADER_Y, COLOR_FG, COLOR_BG);

	const int VAL_LEN = 5;
	int x = (TFT_VISIBLE_W - VAL_LEN * BIG_CELL_W) / 2;
	/* Unknown / NTC open until a valid reading arrives. */
	draw_text_big_at(x, TEMP_VALUE_Y, "-- oC", COLOR_FG, COLOR_BG);

	/* Paint status bar immediately so the screen is never "empty". */
	status_invalidate();
	status_force_redraw(0, false, false, false);
	return x;
}

/*
 * Boot splash → TEMP. Runs once, fully, before the main loop so we never
 * sit forever on ISPOON PRO or blend splash with TEMP mid-frame.
 */
static int boot_splash_then_temp(char *prev_buf, int *last_temp_out)
{
	int64_t hold_end;

	show_splash_animated();
	hold_end = k_uptime_get() + SPLASH_HOLD_MS;
	while (k_uptime_get() < hold_end) {
		watchdog_feed_main();
		k_msleep(40);
	}

	int val_x = show_temp_layout();
	if (last_temp_out) {
		*last_temp_out = TEMP_DISPLAY_INVALID;
	}
	if (prev_buf) {
		memcpy(prev_buf, "-- oC", 5);
		prev_buf[5] = 0;
	}
	LOG_INF("boot UI: TEMP screen active (splash done)");
	return val_x;
}

/* ================= DEEP SLEEP (SYSTEM OFF) ================= */
/*
 * System OFF (~1-3 uA). Wake: HIGH level on the touch pin -> chip
 * RESETS and execution restarts at main(). The nPM1300 is on its own
 * rail and keeps charging from USB while the nRF52840 sleeps.
 *
 * IMPORTANT: nRF GPIO sense is LEVEL-based. If assembly pressure holds
 * the TTP223 output permanently HIGH, System OFF wakes immediately.
 * enter_power_off() handles that with soft-off.
 *
 * Caller must tear down BLE / TFT first. Never returns.
 */
static void enter_deep_sleep(void)
{
    LOG_INF("Entering System OFF — touch P0.%02d to wake", TOUCH_PIN);

    /* Let the IMU thread park (it polls imu_thread_enabled every
     * IMU_IDLE_POLL_MS) so the bus is idle, then stop the sensor itself.
     * This is done HERE and not in enter_power_off(), because that path can
     * divert into soft_off_wait_wake(), which needs the IMU running to catch
     * the double-knock wake. */
    k_msleep(IMU_IDLE_POLL_MS);
    bmi270_suspend();

    nrf_gpio_cfg_input(TOUCH_PIN, NRF_GPIO_PIN_NOPULL);
    nrf_gpio_cfg_sense_set(TOUCH_PIN, NRF_GPIO_PIN_SENSE_HIGH);

    k_msleep(20);                 /* let RTT log lines flush */

    (void)irq_lock();
    sys_poweroff();

    while (1) { k_cpu_idle(); }   /* unreachable */
}

/* enter_power_off / soft_off_wait_wake are defined after touch_dt_* */

/* ---------- Capacitive DOUBLE-TAP (proper / production) ----------
 *
 * Single contact → nothing.
 * Two releases in the tap-duration band, with a short gap → power OFF.
 *
 * Rules that make it feel reliable on TTP223 + wire:
 *   - Light debounce (chip already filters)
 *   - Wide press window (25–450 ms)
 *   - Bounce after tap1 does NOT erase tap1
 *   - Missed second tap just clears; user can try again immediately
 *   - Wake finger still on pad is not counted as tap1
 */

typedef struct {
	int stable_level;
	int run_level;
	int run_count;
	bool pressing;
	int64_t press_start;
	int taps;                  /* 0 idle, 1 waiting for 2nd */
	int taps_needed;
	int64_t last_tap_up;
	int64_t cooldown_until;
} touch_dt_t;

static bool touch_dt_is_held(const touch_dt_t *s)
{
	return s->pressing &&
	       (s->stable_level == 1) &&
	       (s->taps == 0) &&
	       (s->cooldown_until == 0);
}

static void touch_dt_init(touch_dt_t *s, int initial_level, int64_t now,
			  int taps_needed)
{
	int lvl = (initial_level != 0) ? 1 : 0;

	/*
	 * If pad is already HIGH (wake finger / residual), settle as HIGH
	 * without pressing — first action must be a clean release then tap.
	 */
	s->stable_level = lvl;
	s->run_level = lvl;
	s->run_count = TOUCH_CONSENSUS_N;
	s->pressing = false;
	s->press_start = now;
	s->taps = 0;
	s->taps_needed = 2;
	(void)taps_needed;
	s->last_tap_up = 0;
	s->cooldown_until = 0;
}

/* Feed one raw sample. Returns true ONLY for a completed double-tap. */
static bool touch_dt_feed(touch_dt_t *s, int raw, int64_t now)
{
	raw = (raw != 0) ? 1 : 0;

	/* After successful double-tap: ignore until timer ends and pad is LOW. */
	if (s->cooldown_until != 0) {
		if (now < s->cooldown_until) {
			s->stable_level = raw;
			s->run_level = raw;
			s->run_count = 0;
			s->pressing = false;
			s->taps = 0;
			return false;
		}
		if (raw != 0) {
			return false; /* wait for finger off */
		}
		s->cooldown_until = 0;
		s->stable_level = 0;
		s->run_level = 0;
		s->run_count = TOUCH_CONSENSUS_N;
		s->pressing = false;
		s->taps = 0;
		s->last_tap_up = 0;
		return false;
	}

	/* First tap alone timed out — clear and allow immediate retry. */
	if (s->taps == 1 && s->last_tap_up != 0 &&
	    (now - s->last_tap_up) > TOUCH_DOUBLE_GAP_MS) {
		s->taps = 0;
		s->last_tap_up = 0;
		s->pressing = false;
		/* no cooldown — user can double-tap again right away */
	}

	/* Consensus debounce */
	if (raw == s->run_level) {
		if (s->run_count < TOUCH_CONSENSUS_N) {
			s->run_count++;
		}
	} else {
		s->run_level = raw;
		s->run_count = 1;
	}

	if (s->run_count < TOUCH_CONSENSUS_N) {
		return false;
	}

	int level = s->run_level;
	if (level == s->stable_level) {
		return false;
	}

	int prev = s->stable_level;
	s->stable_level = level;

	/* ----- Rising edge: finger down ----- */
	if (level == 1 && prev == 0) {
		if (s->taps == 1 && s->last_tap_up != 0) {
			int64_t gap = now - s->last_tap_up;

			if (gap < TOUCH_INTER_TAP_MIN_MS) {
				/*
				 * Bounce right after release — keep waiting
				 * for a real second tap; do NOT wipe tap1.
				 */
				return false;
			}
			if (gap > TOUCH_DOUBLE_GAP_MS) {
				/* Too late for double — this becomes a new first press. */
				s->taps = 0;
				s->last_tap_up = 0;
			}
		}

		s->pressing = true;
		s->press_start = now;
		return false;
	}

	/* ----- Falling edge: finger up = one tap candidate ----- */
	if (level == 0 && prev == 1) {
		if (!s->pressing) {
			/* Was already high at init / bounce — ignore */
			return false;
		}

		int64_t dur = now - s->press_start;

		s->pressing = false;

		if (dur < TOUCH_TAP_MIN_MS) {
			/* Spike — ignore, keep any pending tap1 */
			return false;
		}
		if (dur > TOUCH_TAP_MAX_MS) {
			/* Long grip / rest — cancel double sequence */
			s->taps = 0;
			s->last_tap_up = 0;
			return false;
		}

		/* Valid tap */
		s->taps++;
		s->last_tap_up = now;

		if (s->taps == 1) {
			LOG_DBG("touch: tap1 ok dur=%d", (int)dur);
			return false;
		}

		/* Double-tap complete */
		s->taps = 0;
		s->last_tap_up = 0;
		s->cooldown_until = now + TOUCH_COOLDOWN_MS;
		LOG_INF("double-tap OFF (dur last=%d ms)", (int)dur);
		return true;
	}

	return false;
}

/*
 * Soft off when capacitive pin is stuck HIGH (housing pressure on wire).
 * Display/BLE already off. Stay dark until double-knock / double-tap,
 * or until pin goes LOW long enough for real System OFF.
 * Never returns (reboots on wake).
 */
static void soft_off_wait_wake(void)
{
	touch_dt_t wake_dt;
	int64_t arm_ms;
	int64_t low_since = 0;

	LOG_WRN("SOFT OFF: pad stuck HIGH (assembly). Double-knock or "
		"double-tap handle to wake; fix wire pressure for true sleep.");

	/* IMU stays on for knock; bite off. */
	atomic_set(&bite_run_atomic, 0);
	atomic_set(&imu_thread_enabled, 1);
	atomic_set(&knock_double_event, 0);

	touch_dt_init(&wake_dt, gpio_pin_get(gpio0, TOUCH_PIN),
		      k_uptime_get(), 2);
	arm_ms = k_uptime_get() + 800;

	while (1) {
		watchdog_feed_main();
		int64_t now = k_uptime_get();
		int raw = gpio_pin_get(gpio0, TOUCH_PIN);

		/* Pad finally released → real System OFF (uA sleep). */
		if (raw == 0) {
			if (low_since == 0) {
				low_since = now;
			} else if ((now - low_since) >= 300) {
				atomic_set(&imu_thread_enabled, 0);
				enter_deep_sleep();
			}
		} else {
			low_since = 0;
		}

		bool wake = false;

		if (now >= arm_ms) {
			wake = touch_dt_feed(&wake_dt, raw, now);
			if (atomic_cas(&knock_double_event, 1, 0)) {
				LOG_INF("soft-off wake by IMU double-knock");
				wake = true;
			}
		} else {
			(void)touch_dt_feed(&wake_dt, raw, now);
		}

		if (wake) {
			LOG_INF("soft-off wake — cold reboot to full ON");
			k_msleep(30);
			sys_reboot(SYS_REBOOT_COLD);
		}

		k_msleep(20);
	}
}

/*
 * Power OFF after UI teardown.
 * Prefer true System OFF when pad can go LOW. If assembly keeps pin HIGH,
 * fall back to soft-off so the spoon stays dark instead of reboot-looping.
 *
 * Assembly fix (best long-term):
 *  - Do not crush electrode wire between shell halves
 *  - Glue thin foil only on outer touch zone; leave air gap inside
 *  - Lower TTP223 sensitivity (AHLB / smaller Cs cap)
 *  - Shorter electrode; series R ~1–4.7 kΩ on sense wire
 */
static void enter_power_off(void)
{
	int64_t t0 = k_uptime_get();

	LOG_INF("Power OFF: wait for pad LOW then System OFF");

	/* After a double-tap the pin may still be HIGH briefly — wait. */
	while ((k_uptime_get() - t0) < 1500) {
		watchdog_feed_main();
		if (gpio_pin_get(gpio0, TOUCH_PIN) == 0) {
			enter_deep_sleep(); /* never returns */
		}
		k_msleep(10);
	}

	/* Still HIGH: housing compressing sense wire → soft-off. */
	soft_off_wait_wake(); /* never returns */
}

/*
 * Power-ON after System OFF / reset.
 *
 * Pad HIGH is required to leave System OFF (sense). Accept:
 *   - stable HIGH ~60 ms (finger still on pad), or
 *   - pad already released within a short window (fast tap that woke us).
 * Double-tap is used only for power-OFF while the UI is running.
 */
static bool wait_for_power_on(void)
{
	int64_t boot_ms = k_uptime_get();
	int64_t high_since = 0;
	bool saw_high = false;

	while (1) {
		watchdog_feed_main();
		int64_t now = k_uptime_get();
		int raw = gpio_pin_get(gpio0, TOUCH_PIN);

		if (raw == 1) {
			if (!saw_high) {
				saw_high = true;
				high_since = now;
			} else if ((now - high_since) >= 60) {
				LOG_INF("touch wake confirmed — power ON");
				return true;
			}
		} else {
			/* Sense wake already happened; pad released → stay ON. */
			if ((now - boot_ms) >= 120) {
				LOG_INF("post-wake idle — power ON");
				return true;
			}
			saw_high = false;
		}

		if ((now - boot_ms) > TOUCH_BOOT_TIMEOUT_MS) {
			LOG_WRN("Touch unresolved — sleeping");
			return false;
		}

		k_msleep(TOUCH_POLL_MS);
	}
}

/* ---- BOOT-STAGE ADC PROBE ----
 * Reads AIN0 once and logs the raw count with a stage tag. Called
 * between every init step so RTT shows EXACTLY which initialization
 * kills the NTC reading (raw healthy ~1590-1900 -> dead ~0-100).
 * This replaces guesswork about overlay/peripheral conflicts. */
static const struct adc_dt_spec *probe_spec;
static struct adc_sequence  probe_seq;
static int16_t              probe_sample;

/* Results are ALSO stored so they can be shown ON THE DISPLAY —
 * no RTT/J-Link needed with the GUI-flasher workflow. */
#define NTC_DIAG_ON_SCREEN 0
#define PROBE_MAX 6
static int probe_raw[PROBE_MAX];
static int probe_ret[PROBE_MAX];
static int probe_count;

static void adc_probe(const char *stage)
{
    if (!probe_spec) return;
    k_mutex_lock(&adc_mutex, K_FOREVER);
    int ret = adc_read_dt(probe_spec, &probe_seq);
    k_mutex_unlock(&adc_mutex);
    LOG_INF("ADC probe [%s]: ret=%d raw=%d", stage, ret,
            (ret == 0) ? (int)probe_sample : -1);
    if (probe_count < PROBE_MAX) {
        probe_ret[probe_count] = ret;
        probe_raw[probe_count] = (ret == 0) ? (int)probe_sample : -1;
        probe_count++;
    }
}

#if NTC_DIAG_ON_SCREEN
/* Full-screen diagnostic page, shown ~8 s after init.
 * Line format "N:RRRR" = probe stage N raw value.
 * Stages: 1 boot  2 gpio  3 tft  4 imu  5 pmic  6 ble
 * Healthy raw ~1600-1900; dead ~0-100. Bottom line = LIVE raw,
 * refreshed 5x/s — pinch the NTC and watch it move (or not). */
static void ntc_diag_screen(void)
{
    fill_color(COLOR_BG);
    draw_text_small_at(UI_SAFE_X0, UI_SAFE_Y0, "ADC DIAG", COLOR_FG, COLOR_BG);

    char line[16];
    for (int i = 0; i < probe_count; i++) {
        if (probe_ret[i] == 0) {
            snprintf(line, sizeof(line), "%d:%d", i + 1, probe_raw[i]);
        } else {
            snprintf(line, sizeof(line), "%d:E%d", i + 1, -probe_ret[i]);
        }
        draw_text_small_at(UI_SAFE_X0, UI_SAFE_Y0 + 12 + i * 10, line,
                           COLOR_FG, COLOR_BG);
    }

    /* Live raw for 8 s on the right side */
    draw_text_small_at(UI_SAFE_X0 + 78, UI_SAFE_Y0, "LIVE:", COLOR_FG, COLOR_BG);
    int64_t until = k_uptime_get() + 8000;
    char prev[8] = "";
    while (k_uptime_get() < until) {
        watchdog_feed_main();
        k_mutex_lock(&adc_mutex, K_FOREVER);
        int ret = adc_read_dt(probe_spec, &probe_seq);
        k_mutex_unlock(&adc_mutex);
        snprintf(line, sizeof(line), "%5d",
                 (ret == 0) ? (int)probe_sample : -1);
        if (strcmp(line, prev) != 0) {
            fill_rect(UI_SAFE_X0 + 78, UI_SAFE_Y0 + 12,
                      5 * SMALL_CELL_W + 4, SMALL_CELL_H, COLOR_BG);
            draw_text_small_at(UI_SAFE_X0 + 78, UI_SAFE_Y0 + 12, line,
                               COLOR_FG, COLOR_BG);
            strcpy(prev, line);
        }
        k_msleep(200);
    }
}
#endif

/* ================= MAIN ================= */

int main(void)
{
    gpio0   = DEVICE_DT_GET(DT_NODELABEL(gpio0));
    watchdog_dev = DEVICE_DT_GET(DT_NODELABEL(wdt0));
    charger_dev = DEVICE_DT_GET(DT_NODELABEL(npm1300_charger));

    if (!device_is_ready(gpio0)) {
        return -ENODEV;
    }

    /* Heater EN (P0.15, active HIGH): output LOW + internal pull-down so the
     * pin cannot float high during reset/boot before the TPS I2C rail is
     * verified. Pull-down stays enabled for the life of the output. */
    if (gpio_pin_configure(gpio0, TPS_EN_PIN,
                           GPIO_OUTPUT_LOW | GPIO_PULL_DOWN) < 0) {
        return -EIO;
    }

    /* An MCUboot TEST image must initialize and self-confirm without waiting
     * for a user touch; otherwise a headless OTA reboot would sleep forever
     * unconfirmed. A health timeout below forces a reboot and rollback. */
    bool image_needs_confirmation = !boot_is_img_confirmed();
    int64_t image_validation_started_ms = k_uptime_get();

    /* Arm rollback coverage immediately after the heater is proven off.
     * The safety thread starts fail-closed; readiness atomics are enabled
     * only after each peripheral passes initialization. */
    bool watchdog_ready = (watchdog_start() == 0);
    bool safety_thread_ready = (heater_safety_start() == 0);
    if (!watchdog_ready) {
        LOG_ERR("Watchdog unavailable; heater permanently disabled");
    }
    if (!safety_thread_ready) {
        LOG_ERR("Heater safety thread failed to start");
        if (watchdog_ready) {
            /* The unfed safety watchdog channel deliberately resets this
             * unconfirmed image so MCUboot can roll it back. */
            while (1) {
                watchdog_feed_main();
                k_msleep(100);
            }
        }
    }

    spi_dev = DEVICE_DT_GET(SPI_NODE);
    gpio1   = DEVICE_DT_GET(DT_NODELABEL(gpio1));
    i2c_dev = DEVICE_DT_GET(I2C_NODE);
    imu_dev = DEVICE_DT_GET_ONE(bosch_bmi270);

    /* ----- Minimal bringup to check the touch wake-up ----- */
    gpio_pin_configure(gpio0, TOUCH_PIN, GPIO_INPUT);

    LOG_INF("boot: touch pin P0.%02d reads %d (normal double-tap OFF)",
            TOUCH_PIN, gpio_pin_get(gpio0, TOUCH_PIN));

#if !DEBUG_FORCE_ON
    if (!image_needs_confirmation && !wait_for_power_on()) {
        LOG_INF("no wake confirm — entering System OFF");
        enter_deep_sleep();        /* never returns */
    }
    if (image_needs_confirmation) {
        LOG_INF("MCUboot TEST image: bypassing touch gate for validation");
    } else {
        LOG_INF("power ON — starting UI + BLE");
    }
#else
    LOG_WRN("DEBUG_FORCE_ON=1: always ON (bench only)");
#endif

    /* ----- Full hardware bringup ----- */
    /* ---- ADC first, so the probe can watch every later init ---- */
    /* ADC via DEVICETREE (NCS v3.3.1 requires this — the runtime
     * .input_positive path silently fails to bind AIN0 on Zephyr 4.3,
     * giving a floating ~100-count read. The channel is declared in
     * the overlay under /zephyr,user + &adc/channel@0. */
    bool adc_ready = false;
    if (!adc_is_ready_dt(&heater_adc_channel)) {
        LOG_ERR("ADC not ready");
    } else if (adc_channel_setup_dt(&heater_adc_channel) < 0) {
        LOG_ERR("ADC channel setup failed");
    } else {
        adc_ready = true;
    }
    int16_t sample;
    struct adc_sequence seq = {
        .buffer      = &sample,
        .buffer_size = sizeof(sample),
        .resolution  = 12,
    };
    seq.channels = BIT(heater_adc_channel.channel_id);
    probe_spec = &heater_adc_channel; probe_seq = seq;
    probe_seq.buffer = &probe_sample;

    adc_probe("boot/pre-everything");
    watchdog_feed_main();

    gpio_pin_configure(gpio1, TFT_CS_PIN,  GPIO_OUTPUT_HIGH);
    gpio_pin_configure(gpio1, TFT_DC_PIN,  GPIO_OUTPUT_HIGH);
    gpio_pin_configure(gpio1, TFT_RST_PIN, GPIO_OUTPUT_HIGH);
    gpio_pin_configure(gpio0, LED_PIN,     GPIO_OUTPUT_HIGH);
    atomic_set(&adc_ready_atomic, adc_ready ? 1 : 0);
    adc_probe("after gpio cfg");
    watchdog_feed_main();

    /*
     * TFT first, then paint UI IMMEDIATELY.
     *
     * Previous order left the panel ON with a solid black GRAM for the whole
     * BMI270 / nPM1300 / TPS / BLE bring-up (often several seconds, longer if
     * settings/NVS is cold). Double-tap wake looked like "display on, blank
     * UI" even though the firmware was still initializing.
     */
    if (!device_is_ready(spi_dev) || !device_is_ready(gpio1)) {
        LOG_ERR("TFT bus not ready (spi=%d gpio1=%d)",
                device_is_ready(spi_dev), device_is_ready(gpio1));
    }

    /* Panel polarity must be known BEFORE the first pixel. settings_load()
     * for BLE bonds runs much later (inside BLE init), so pull just our own
     * subtree up front. settings_subsys_init() is idempotent, so the later
     * full load is unaffected. */
    {
        int serr = settings_subsys_init();
        if (serr) {
            LOG_WRN("settings init failed (%d) — panel uses build default", serr);
        } else {
            (void)settings_load_subtree("ispoon");
        }
        LOG_INF("panel: inversion %s", panel_invert ? "ON" : "OFF");
    }

    tft_init();                            /* clears bg, then display ON */
    watchdog_feed_main();
    adc_probe("after tft_init");
    gpio_pin_set(gpio0, LED_PIN, 0);       /* LED on (active-low) */

    /* ----- Per-on-cycle UI state (needed before early splash) ----- */
    int     val_x = 0;
    int     last_temp = TEMP_DISPLAY_INVALID;
    char    prev_buf[8] = "-- oC";

    /*
     * Boot UI (strict, synchronous — right after panel ON):
     *   1) black/white GRAM (tft_init)
     *   2) ISPOON PRO splash (once)
     *   3) full clear + TEMP + status  ← stays here; no splash again
     * Slow I2C/BLE init continues BELOW with TEMP already on screen.
     */
    val_x = boot_splash_then_temp(prev_buf, &last_temp);
    ui = UI_TEMP;
    watchdog_feed_main();

    /* ----- I2C devices (TEMP already visible) ----- */
    bool imu_ready = (bmi270_init() == 0);
    watchdog_feed_main();
    if (!imu_ready) {
        LOG_WRN("BMI270 init failed — check I2C wiring / overlay address 0x68");
    } else if (bmi270_selftest() != 0) {
        LOG_WRN("BMI270 present but IMU self-test failed — no motion data");
        imu_ready = false;
    }
    adc_probe("after bmi270_init");

    bool pmic_ready = (npm_init() == 0);
    watchdog_feed_main();
    atomic_set(&pmic_ready_atomic, pmic_ready ? 1 : 0);
    if (!pmic_ready) LOG_WRN("nPM1300 init failed");
    adc_probe("after npm_init");

    bool tps_ready = (tps_init() == 0) &&
                     watchdog_ready && safety_thread_ready;
    watchdog_feed_main();
    atomic_set(&tps_ready_atomic, tps_ready ? 1 : 0);
    if (!tps_ready) LOG_WRN("TPS628682 init failed");
    adc_probe("after tps_init");

    /* ----- BLE ----- */
    mgmt_callback_register(&dfu_mgmt_cb);
    mgmt_callback_register(&reset_mgmt_cb);

    bool ble_ready = (ble_setup() == 0);
    watchdog_feed_main();
    if (!ble_ready) {
        LOG_ERR("BLE setup failed");
    }
    adc_probe("after ble_setup");
    if (ble_ready) {
        maybe_reset_owner_bond();
    }

#if NTC_DIAG_ON_SCREEN
    ntc_diag_screen();          /* 8 s diag page, then restore TEMP */
    val_x = show_temp_layout();
    last_temp = TEMP_DISPLAY_INVALID;
    memcpy(prev_buf, "-- oC", 5);
    prev_buf[5] = 0;
    ui = UI_TEMP;
#endif

    /* Double-tap OFF + long-hold owner-reset. Touch is polled faster than UI. */
    touch_dt_t touch_off;
    int64_t touch_off_arm_ms = k_uptime_get() + TOUCH_OFF_ARM_MS;
    /* Match real pad level so wake finger is not counted as a rising edge. */
    touch_dt_init(&touch_off, gpio_pin_get(gpio0, TOUCH_PIN),
		  k_uptime_get(), 2);
    int64_t owner_hold_start = 0;
    bool owner_reset_prompt = false;
    int64_t next_ui_ms = k_uptime_get();

    /* Battery polling — non-blocking two-phase measurement. */
    int64_t  next_batt_ms  = 0;
    bool     vbat_pending  = false;
    int64_t  vbat_ready_ms = 0;
    uint16_t batt_mv = 0;          (void)batt_mv;
    uint8_t  batt_pct = 0;
    uint8_t  batt_flags = 0;       /* bit0=USB present, bit1=charge UI (bolt) */

    bool last_charging   = false;
    int  transient_left  = 0;
    bool batt_pct_valid  = false;
    bool chg_ui_latched  = false;  /* debounced plug/charge icon */
    int  chg_ui_agree    = 0;      /* consecutive samples matching want */

    bool warn_armed = true;        /* 55 C high-temp hysteresis */
    int  temp_warn_streak = 0;     /* consecutive readings >= 55 C */
    bool image_confirm_attempted = false;
    int64_t image_health_since_ms = 0;

    /* ----- Start the on-cycle ----- */
    bite_reset();
    atomic_set(&bite_run_atomic, imu_ready ? 1 : 0);
    adc_filter_reset();
    status_invalidate();
    /* Re-paint status strip now that battery path is about to run. */
    status_force_redraw(0, false, false, false);
    int64_t now0 = k_uptime_get();
    next_batt_ms = now0;

    adv_kick(true);                        /* fitness-band mode: ON */
    atomic_set(&imu_thread_enabled, 1);

    while (1) {
        watchdog_feed_main();

        /* Panel polarity change requested over BLE. Applied HERE because this
         * thread owns the panel SPI. INVON/INVOFF acts on what is already in
         * GRAM, so the whole screen flips immediately — the installer sees the
         * result at once and can pick the right value by eye. */
        {
            atomic_val_t inv_req = atomic_set(&panel_invert_req, -1);
            if (inv_req >= 0) {
                panel_invert = (uint8_t)inv_req;
                tft_cmd(panel_invert ? 0x21 : 0x20);
                int serr = settings_save_one("ispoon/inv", &panel_invert,
                                             sizeof(panel_invert));
                LOG_INF("panel: inversion %s%s", panel_invert ? "ON" : "OFF",
                        serr ? " (SAVE FAILED)" : " (saved)");
            }
        }

        /* ============== TOUCH (normal double-tap) ==============
         * Single touch → ignored
         * Double-tap → power OFF
         * Long hold 6 s → clear owner bond
         * IMU double-knock also accepted as backup */
        int64_t now = k_uptime_get();
        int touch = gpio_pin_get(gpio0, TOUCH_PIN);

        /* Always feed capacitive detector so debounce/baseline stay fresh. */
        bool double_tap = false;
        if (now >= touch_off_arm_ms) {
            double_tap = touch_dt_feed(&touch_off, touch, now);
            if (atomic_cas(&knock_double_event, 1, 0)) {
                LOG_INF("power-off by IMU double-knock");
                double_tap = true;
            }
        } else {
            (void)touch_dt_feed(&touch_off, touch, now);
            (void)atomic_set(&knock_double_event, 0);
        }

        if (double_tap) {
            if (image_needs_confirmation) {
                LOG_WRN("power-off blocked: MCUboot TEST image validating");
                touch_dt_init(&touch_off, touch, now, 2);
#if DEBUG_FORCE_ON
            } else {
                LOG_WRN("DEBUG_FORCE_ON: ignore double-tap power-off");
                touch_dt_init(&touch_off, touch, now, 2);
#else
            } else {
                atomic_set(&imu_thread_enabled, 0);
                atomic_set(&bite_run_atomic, 0);

                heater_force_off("local power-off", false);
                ble_shutdown();

                tft_sleep();
                gpio_pin_set(gpio0, LED_PIN, 1);

                enter_power_off();    /* System OFF or soft-off; never returns */
#endif
            }
        }

        /*
         * Owner reset: logical hold only (stable != idle). Copper tape that
         * leaves the pin stuck HIGH is relearned as idle and must NOT start
         * the 6 s bond-clear timer. Ignore mid double-tap / cooldown.
         */
        bool pad_held = touch_dt_is_held(&touch_off);
        if (pad_held && atomic_get(&owner_bond_present)) {
            if (owner_hold_start == 0) {
                owner_hold_start = now;
                owner_reset_prompt = false;
            } else if (!owner_reset_prompt &&
                       (now - owner_hold_start) >= 1500) {
                draw_text_small_at(UI_SAFE_X0, STATUS_Y, "HOLD=RESET", COLOR_FG, COLOR_BG);
                owner_reset_prompt = true;
            } else if ((now - owner_hold_start) >= OWNER_RESET_HOLD_MS) {
                owner_bond_reset_perform();
                owner_hold_start = 0;
                owner_reset_prompt = false;
                touch_dt_init(&touch_off, touch, now, 2);
                touch_off_arm_ms = now + TOUCH_OFF_ARM_MS;
                val_x = show_temp_layout();
                last_temp = TEMP_DISPLAY_INVALID;
                memcpy(prev_buf, "-- oC", 5);
                prev_buf[5] = 0;
                status_invalidate();
                ui = UI_TEMP;
                next_ui_ms = k_uptime_get();
            }
        } else {
            if (owner_reset_prompt) {
                status_invalidate();
            }
            owner_hold_start = 0;
            owner_reset_prompt = false;
        }

        /* Skip heavy UI this cycle if we only need touch sampling. */
        if (now < next_ui_ms) {
            k_msleep(TOUCH_POLL_MS);
            continue;
        }
        next_ui_ms = now + LOOP_MS;

        /* A TEST image becomes permanent only after a continuous healthy
         * dwell. Failure to reach that state causes a cold reset so MCUboot
         * restores the previous confirmed image. */
        if (image_needs_confirmation && !image_confirm_attempted) {
            /*
             * Do NOT require ntc_valid — open NTC ("-- oC") is a valid product
             * state. Requiring NTC forced 60 s reboot loops that re-showed
             * only ISPOON PRO forever on boards without a probe fitted.
             */
            bool image_healthy =
                watchdog_ready && safety_thread_ready &&
                pmic_ready && tps_ready && ble_ready &&
                atomic_get(&adc_ready_atomic) &&
                atomic_get(&battery_status_valid) &&
                !atomic_get(&heater_fault_atomic) &&
                !atomic_get(&heater_on_atomic) &&
                !atomic_get(&tps_rail_state);

            if (!image_healthy) {
                image_health_since_ms = 0;
            } else if (image_health_since_ms == 0) {
                image_health_since_ms = now;
            } else if ((now - image_health_since_ms) >=
                       IMAGE_HEALTH_DWELL_MS) {
                image_confirm_attempted = true;
                int confirm_err = boot_write_img_confirmed();
                if (confirm_err) {
                    LOG_ERR("MCUboot image confirmation failed (%d)",
                            confirm_err);
                    heater_force_off("image confirmation failed", false);
                    sys_reboot(SYS_REBOOT_COLD);
                }
                image_needs_confirmation = false;
                LOG_INF("MCUboot TEST image confirmed after stable health");
            }

            if ((now - image_validation_started_ms) >=
                IMAGE_VALIDATION_TIMEOUT_MS) {
                heater_force_off("image health validation timeout", false);
                LOG_ERR("MCUboot TEST image unhealthy; rebooting to rollback");
                sys_reboot(SYS_REBOOT_COLD);
            }
        }

        /* ============== UI ============== */
        switch (ui) {
        case UI_BLANK:
        case UI_SPLASH:
            /* Recovery only — NEVER re-animate ISPOON PRO (avoids mix/stuck). */
#if PMIC_DEBUG_VIEW
            pmic_debug_init_screen();
#else
            val_x = show_temp_layout();
            last_temp = TEMP_DISPLAY_INVALID;
            memcpy(prev_buf, "-- oC", 5);
            prev_buf[5] = 0;
            adc_filter_reset();
#endif
            next_batt_ms = now;
            ui = UI_TEMP;
            break;

        case UI_TEMP: {
            /* SMP upload in progress — freeze TEMP and show DFU so the user
             * does not think the spoon is idle while the slot is being written. */
            static bool dfu_screen_painted;
            if (atomic_get(&dfu_locked_atomic)) {
                if (!dfu_screen_painted) {
                    fill_color(COLOR_BG);
                    draw_text_big_center("DFU", TEMP_HEADER_Y, COLOR_FG, COLOR_BG);
                    dfu_screen_painted = true;
                    status_invalidate();
                }
                break;
            }
            if (dfu_screen_painted) {
                dfu_screen_painted = false;
                val_x = show_temp_layout();
                memcpy(prev_buf, "-- oC", 5);
                prev_buf[5] = 0;
                last_temp = TEMP_DISPLAY_INVALID;
            }

            /* Full layout refresh — keeps TEMP clean, no splash ghosts. */
            static int64_t next_full_paint_ms;
            if (next_full_paint_ms == 0) {
                next_full_paint_ms = now + 1500;
            }
            if (now >= next_full_paint_ms) {
                next_full_paint_ms = now + 3000;
                /* Redraw header + value + status without full black flash. */
                draw_text_big_center("TEMP", TEMP_HEADER_Y, COLOR_FG, COLOR_BG);
                temp_draw_value_force(val_x, last_temp, prev_buf);
                status_invalidate();
                status_update(batt_pct,
                              atomic_get(&bt_connected) != 0,
                              atomic_get(&tps_rail_state) != 0,
                              (batt_flags & 0x02) != 0);
            }

            /* --- Battery: two-phase, never blocks the loop --- */
            if (pmic_ready && !vbat_pending && now >= next_batt_ms) {
                if (npm_vbat_trigger() == 0) {
                    vbat_pending  = true;
                    vbat_ready_ms = now + VBAT_CONV_TIME_MS;
                } else {
                    next_batt_ms = now + BATT_POLL_MS;   /* retry later */
                }
            }

            if (pmic_ready && vbat_pending && now >= vbat_ready_ms) {
                vbat_pending = false;
                next_batt_ms = now + BATT_POLL_MS;

                uint16_t mv = npm_vbat_read_mv();
                if (mv > 0) {
                    uint8_t vbus_stat =
                        (uint8_t)atomic_get(&npm_cached_vbus_status);
                    uint8_t chg_stat =
                        (uint8_t)atomic_get(&npm_cached_charge_status);

                    bool vbus_present =
                        (vbus_stat & NPM_VBUS_PRESENT) != 0;
                    bool actively_charging =
                        (chg_stat & NPM_CHGSTAT_CHARGING) != 0;
                    /*
                     * Show charge UI whenever USB is present (and while
                     * CC/CV/trickle is active). Do NOT key the icon only
                     * on CHARGING bits — those toggle CC<->CV and go idle
                     * at full charge, which looked like connect/disconnect.
                     */
                    bool charge_ui_want = vbus_present || actively_charging;

                    if (charge_ui_want == chg_ui_latched) {
                        chg_ui_agree = 0;
                    } else if (++chg_ui_agree >= CHG_UI_DEBOUNCE_SAMPLES) {
                        chg_ui_latched = charge_ui_want;
                        chg_ui_agree = 0;
                    }

                    bool charging = chg_ui_latched;

                    if (batt_pct_valid && charging != last_charging) {
                        transient_left = SOC_TRANSIENT_SAMPLES;
                    }
                    last_charging = charging;

                    /* Gauge from the IR-compensated open-circuit estimate,
                     * not the loaded terminal voltage, so the number does not
                     * jump when the charger is plugged in or pulled out. */
                    uint8_t raw_pct = npm_battery_percent(npm_vbat_ocv_mv(mv));

                    /* The charger stops at VTERM and the cell then relaxes a
                     * few tens of mV, so a voltage-only gauge sticks at
                     * 97-99 %% and never shows a full battery. The PMIC
                     * already tells us charging finished - trust that. */
                    if (vbus_present &&
                        (chg_stat & NPM_CHGSTAT_COMPLETE) != 0U) {
                        raw_pct = 100;
                    }

                    uint8_t shown_pct;
                    if (!batt_pct_valid) {
                        shown_pct = raw_pct;
                        batt_pct_valid = true;
                    } else if (transient_left > 0) {
                        int16_t delta = (int16_t)raw_pct - (int16_t)batt_pct;
                        if (delta >  SOC_SLEW_MAX_PCT) delta =  SOC_SLEW_MAX_PCT;
                        if (delta < -SOC_SLEW_MAX_PCT) delta = -SOC_SLEW_MAX_PCT;
                        shown_pct = (uint8_t)((int16_t)batt_pct + delta);
                        transient_left--;
                    } else {
                        shown_pct = raw_pct;
                    }

                    uint8_t flags = 0;
                    if (vbus_present) flags |= 0x01;
                    if (charging)     flags |= 0x02;

                    batt_mv = mv; batt_pct = shown_pct; batt_flags = flags;

                    atomic_set(&shared_battery_pct, (atomic_val_t)batt_pct);
                    /* Standard BAS — readable before product-service bond. */
                    (void)bt_bas_set_battery_level(batt_pct);

#if PMIC_DEBUG_VIEW
                    pmic_debug_update();
#endif
                }
            }

#if !PMIC_DEBUG_VIEW
            /* --- Status bar --- */
            status_update(batt_pct,
                          atomic_get(&bt_connected) != 0,
                          atomic_get(&tps_rail_state) != 0,
                          (batt_flags & 0x02) != 0);
            status_tick_blink((batt_flags & 0x02) != 0);

            /* --- Temperature (NTC) ---
             * Disconnected / open / short → show "-- oC", never fake -9.
             * Same raw bounds as the heater safety supervisor. */
            if (heater_adc_read(&sample) == 0) {
                bool ntc_connected =
                    (sample >= NTC_RAW_VALID_MIN &&
                     sample <= NTC_RAW_VALID_MAX);

                float filt = adc_filter_push((int32_t)sample);
#if NTC_MATH_V1
                float v = filt * 2.8f / 4095.0f;
                float t = ntc_temp_with(2.8f, v);
#else
                float v = filt * ADC_FULL_SCALE_V / 4095.0f;
                float t = ntc_temp(v);
#endif

                static int64_t next_ntc_log_ms;
                int64_t now_ms = k_uptime_get();
                if (now_ms >= next_ntc_log_ms) {
                    next_ntc_log_ms = now_ms + 1000;
                    LOG_INF("NTC: raw=%d v=%.3fV t=%.1fC connected=%d",
                            (int)sample, (double)v, (double)t,
                            ntc_connected ? 1 : 0);
                }

                if (!ntc_connected || !isfinite(t)) {
                    /* Open / short / nonsense: dash on UI, invalid BLE temp. */
                    atomic_set(&shared_temp_c100, (atomic_val_t)INT16_MIN);
                    temp_warn_streak = 0;
                    if (last_temp != TEMP_DISPLAY_INVALID) {
                        temp_draw_value_force(val_x, TEMP_DISPLAY_INVALID,
                                              prev_buf);
                        last_temp = TEMP_DISPLAY_INVALID;
                    }
                } else {
                    int32_t tx100 = (int32_t)lroundf(t * 100.0f);
                    if (tx100 >  32767) tx100 =  32767;
                    if (tx100 < -32767) tx100 = -32767; /* keep INT16_MIN free */
                    atomic_set(&shared_temp_c100,
                               (atomic_val_t)(int16_t)tx100);

                    int prev_for_hyst =
                        (last_temp == TEMP_DISPLAY_INVALID) ? INT_MIN
                                                            : last_temp;
                    int t_int = hysteresis_round(t, prev_for_hyst);
                    if (t_int < -9) t_int = -9;
                    if (t_int > 99)  t_int = 99;

                    if (t_int != last_temp) {
                        temp_draw_value(val_x, t_int, prev_buf);
                        last_temp = t_int;
                        LOG_INF("UI temp → %d oC", t_int);
                    }

                    if (t_int >= TEMP_WARN_HIGH_C) {
                        if (temp_warn_streak < TEMP_WARN_DEBOUNCE) {
                            temp_warn_streak++;
                        }
                    } else {
                        temp_warn_streak = 0;
                    }

                    if (warn_armed &&
                        temp_warn_streak >= TEMP_WARN_DEBOUNCE) {
                        LOG_WRN("temp %d C >= %d — high temperature",
                                t_int, TEMP_WARN_HIGH_C);
                        warn_armed = false;
                        temp_warn_streak = 0;
                    } else if (!warn_armed && t_int < TEMP_WARN_REARM_C) {
                        warn_armed = true;
                    }
                }
            } else {
                /* ADC not ready / read failed — keep dashes visible. */
                atomic_set(&shared_temp_c100, (atomic_val_t)INT16_MIN);
                if (last_temp != TEMP_DISPLAY_INVALID) {
                    temp_draw_value_force(val_x, TEMP_DISPLAY_INVALID,
                                          prev_buf);
                    last_temp = TEMP_DISPLAY_INVALID;
                }
                temp_warn_streak = 0;
            }

            /* Bite detection runs at 100 Hz inside imu_thread (BMI270
             * sensor API is not multi-thread safe). */
#endif /* !PMIC_DEBUG_VIEW */
            break;
        }
        }

        /* Return quickly so double-tap stays responsive between UI frames. */
        k_msleep(TOUCH_POLL_MS);
    }

    return 0;                      /* unreachable */
}
