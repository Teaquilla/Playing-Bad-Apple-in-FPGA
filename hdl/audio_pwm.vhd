--------------------------------------------------------------------------------
-- hdl/audio_pwm.vhd
-- Modul Daun Modulator Audio PWM 8-bit 8 kHz (Milestone 4 - Varian B)
--
-- Karakteristik Arsitektur (Varian B):
-- - Clock input: 100 MHz (CLK_FREQ_HZ = 100_000_000)
-- - Laju sampel audio: 8 kHz (SAMPLE_RATE = 8_000)
-- - Frekuensi pembawa PWM (carrier): 400 kHz (periode 250 siklus clock)
-- - Hubungan frekuensi: Tepat 50 periode carrier per tick sampel 8 kHz
--   (12.500 siklus / 250 siklus = 50 periode carrier penuh, tanpa jitter latch)
-- - Pemetaan ambang duty: duty_threshold = (sample_in * 250) >> 8
--   * Sample 0x00 (0)   -> threshold 0   -> duty 0/250 = 0,0%
--   * Sample 0x80 (128) -> threshold 125 -> duty 125/250 = 50,0%
--   * Sample 0xFF (255) -> threshold 249 -> duty 249/250 = 99,6%
-- - Kontrol Enable:
--   * enable = '1': Modulasi aktif mengikuti sample_in
--   * enable = '0': Output dipaksa pada duty 50% (threshold 125, level hening)
-- - Indikator Stroba Permintaan Sampel (sample_req):
--   Pulsa stroba aktif HIGH tepat 1 siklus clock setiap 12.500 siklus (8 kHz).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity audio_pwm is
    generic (
        CLK_FREQ_HZ : positive := 100_000_000;
        SAMPLE_RATE : positive := 8_000
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        enable     : in  std_logic;
        sample_in  : in  std_logic_vector(7 downto 0);
        sample_req : out std_logic;
        pwm_out    : out std_logic
    );
end entity audio_pwm;

architecture rtl of audio_pwm is

    -- Konstanta turunan timing
    constant CARRIER_CYCLES : positive := CLK_FREQ_HZ / (SAMPLE_RATE * 50); -- 250 siklus (400 kHz)
    constant SAMPLE_CYCLES  : positive := CLK_FREQ_HZ / SAMPLE_RATE;        -- 12.500 siklus (8 kHz)
    constant MID_DUTY       : natural  := CARRIER_CYCLES / 2;               -- 125 siklus (50%)

    -- Pencacah carrier dan sample tick
    signal carrier_cnt : integer range 0 to CARRIER_CYCLES - 1 := 0;
    signal sample_cnt  : integer range 0 to SAMPLE_CYCLES - 1  := 0;

    -- Register penahan sampel dan enable (selaras batas periode)
    signal sample_reg  : std_logic_vector(7 downto 0) := x"80";
    signal enable_reg  : std_logic := '1';

begin

    -- Proses utama synchronous clock
    process(clk)
        variable v_duty : integer range 0 to CARRIER_CYCLES;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                carrier_cnt <= 0;
                sample_cnt  <= 0;
                sample_req  <= '0';
                pwm_out     <= '0';
                sample_reg  <= x"80";
                enable_reg  <= '1';
            else
                -- 1. Pencacah Carrier PWM (Modulo 250 siklus = 400 kHz)
                if carrier_cnt = CARRIER_CYCLES - 1 then
                    carrier_cnt <= 0;
                    enable_reg  <= enable; -- Selaraskan perubahan enable ke batas periode carrier
                else
                    carrier_cnt <= carrier_cnt + 1;
                end if;

                -- 2. Pembangkit Stroba Tick Sampel 8 kHz (Modulo 12.500 siklus)
                if sample_cnt = SAMPLE_CYCLES - 1 then
                    sample_cnt <= 0;
                    sample_req <= '1';
                    sample_reg <= sample_in; -- Cuplik sample_in tepat di batas tick sampel
                else
                    sample_cnt <= sample_cnt + 1;
                    sample_req <= '0';
                end if;

                -- 3. Perhitungan Ambang Duty Cycle (Varian B)
                if enable_reg = '0' then
                    v_duty := MID_DUTY;
                else
                    v_duty := (to_integer(unsigned(sample_reg)) * CARRIER_CYCLES) / 256;
                end if;

                -- 4. Pembangkitan Sinyal Keluaran PWM Ter-register
                if carrier_cnt < v_duty then
                    pwm_out <= '1';
                else
                    pwm_out <= '0';
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
