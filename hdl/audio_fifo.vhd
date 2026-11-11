--------------------------------------------------------------------------------
-- hdl/audio_fifo.vhd
-- Modul Daun Buffer Audio FIFO 2.048 Byte (Milestone 4)
--
-- Karakteristik Arsitektur:
-- - Kapasitas Penyimpanan: Tepat 2.048 byte menggunakan 1 blok RAMB18E1.
-- - Pointer Pengalamatan: 12-bit (11-bit alamat memori 0..2047 + 1-bit wrap).
-- - Isi terkomit L = w_commit - r_ptr (0 <= L <= 2048).
--
-- Sisi Tulis (dari packet_parser / UART streaming):
-- - wr_start: pulsa stroba saat header LEN paket audio terbaca.
-- - wr_len: panjang payload paket audio (11-bit).
-- - wr_reject: pulsa aktif HIGH jika ruang kosong < wr_len saat wr_start.
--   Jika ditolak, cnt_overflow bertambah (saturasi 16-bit) dan penulisan diabaikan.
-- - Tulis spekulatif ke w_spec saat wr_valid = '1'.
-- - wr_commit: mengesahkan paket (w_commit <= w_spec).
-- - wr_rollback: membatalkan penulisan spekulatif (w_spec <= w_commit).
--
-- Sisi Baca (ke audio_pwm):
-- - rd_req: pulsa stroba permintaan sampel (dari sample_req audio_pwm).
-- - FWFT (First-Word Fall-Through): rd_data selalu siap menyajikan sampel
--   kepala antrean terkomit sebelum rd_req tiba.
-- - Pre-roll: rd_data mengeluarkan level hening 0x80 hingga L >= 1.024.
--   Setelah L >= 1.024, sinyal playing aktif ('1') secara permanen.
-- - Underflow: Jika playing = '1' dan L = 0 saat rd_req, keluarkan 0x80,
--   cnt_underflow bertambah (saturasi 16-bit), dan status playing tetap '1'.
-- - Kompensasi Slip (Crystal Drift):
--   * Low slip: jika L < 410 terus-menerus >= DWELL_CYCLES, ulangi sampel
--     terakhir (tanpa pop) maks 1x per SLIP_MIN_CYCLES hingga L >= 512.
--     cnt_repeat bertambah.
--   * High slip: jika L > 1.638 terus-menerus >= DWELL_CYCLES, buang 1 sampel
--     (pop dua kali) maks 1x per SLIP_MIN_CYCLES hingga L <= 1.536.
--     cnt_drop bertambah.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity audio_fifo is
    generic (
        DWELL_CYCLES    : natural := 300_000_000; -- Default 3 detik pada 100 MHz
        SLIP_MIN_CYCLES : natural := 5_000_000     -- Default 50 ms pada 100 MHz
    );
    port (
        clk           : in  std_logic;
        rst           : in  std_logic;

        -- Antarmuka Tulis Spekulatif (Sisi Parser)
        wr_start      : in  std_logic;
        wr_len        : in  std_logic_vector(10 downto 0);
        wr_valid      : in  std_logic;
        wr_data       : in  std_logic_vector(7 downto 0);
        wr_commit     : in  std_logic;
        wr_rollback   : in  std_logic;
        wr_reject     : out std_logic;

        -- Antarmuka Baca FWFT (Sisi audio_pwm)
        rd_req        : in  std_logic;
        rd_data       : out std_logic_vector(7 downto 0);

        -- Status dan Telemetri
        level         : out std_logic_vector(11 downto 0);
        playing       : out std_logic;
        cnt_overflow  : out std_logic_vector(15 downto 0);
        cnt_underflow : out std_logic_vector(15 downto 0);
        cnt_drop      : out std_logic_vector(15 downto 0);
        cnt_repeat    : out std_logic_vector(15 downto 0)
    );
end entity audio_fifo;

architecture rtl of audio_fifo is

    -- Kapasitas memori 2.048 byte (1 blok RAMB18E1)
    type ram_type is array (0 to 2047) of std_logic_vector(7 downto 0);
    signal mem : ram_type := (others => (others => '0'));
    attribute ram_style : string;
    attribute ram_style of mem : signal is "block";

    -- Pointer 12-bit (bit 11 = wrap bit, bit 10 downto 0 = alamat BRAM)
    signal w_spec   : unsigned(11 downto 0) := (others => '0');
    signal w_commit : unsigned(11 downto 0) := (others => '0');
    signal r_ptr    : unsigned(11 downto 0) := (others => '0');

    -- Status kendali tulis
    signal reject_latch : std_logic := '0';

    -- Status kendali baca & pre-roll
    signal playing_reg  : std_logic := '0';
    signal bram_dout    : std_logic_vector(7 downto 0) := x"80";

    -- Pencacah saturasi 16-bit
    signal overflow_reg  : unsigned(15 downto 0) := (others => '0');
    signal underflow_reg : unsigned(15 downto 0) := (others => '0');
    signal drop_reg      : unsigned(15 downto 0) := (others => '0');
    signal repeat_reg    : unsigned(15 downto 0) := (others => '0');

    -- Kendali dan pencacah slip
    signal dwell_low_cnt   : natural range 0 to DWELL_CYCLES := 0;
    signal dwell_high_cnt  : natural range 0 to DWELL_CYCLES := 0;
    signal slip_low_mode   : std_logic := '0';
    signal slip_high_mode  : std_logic := '0';
    signal slip_cool_cnt   : natural range 0 to SLIP_MIN_CYCLES := 0;

    -- Sinyal perhitungan level
    signal level_committed : unsigned(11 downto 0);
    signal level_spec      : unsigned(11 downto 0);

begin

    -- Perhitungan tingkat keterisian
    level_committed <= w_commit - r_ptr;
    level_spec      <= w_spec - r_ptr;

    -- Evaluasi kombinasi wr_reject saat wr_start
    wr_reject <= '1' when (wr_start = '1' and ((2048 - to_integer(level_spec)) < to_integer(unsigned(wr_len)))) else '0';

    -- Port keluaran status
    level         <= std_logic_vector(level_committed);
    playing       <= '1' when (playing_reg = '1' or level_committed >= 1024) else '0';
    cnt_overflow  <= std_logic_vector(overflow_reg);
    cnt_underflow <= std_logic_vector(underflow_reg);
    cnt_drop      <= std_logic_vector(drop_reg);
    cnt_repeat    <= std_logic_vector(repeat_reg);

    -- =========================================================================
    -- PROSES UTAMA BRAM & KENDALI FIFO
    -- =========================================================================
    process(clk)
        variable v_free_space : integer;
        variable v_req_len    : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                w_spec         <= (others => '0');
                w_commit       <= (others => '0');
                r_ptr          <= (others => '0');
                reject_latch   <= '0';
                playing_reg    <= '0';
                overflow_reg   <= (others => '0');
                underflow_reg  <= (others => '0');
                drop_reg       <= (others => '0');
                repeat_reg     <= (others => '0');
                dwell_low_cnt  <= 0;
                dwell_high_cnt <= 0;
                slip_low_mode  <= '0';
                slip_high_mode <= '0';
                slip_cool_cnt  <= 0;
                bram_dout      <= x"80";
            else
                -- -------------------------------------------------------------
                -- A. SISI TULIS DARI PARSER
                -- -------------------------------------------------------------
                -- 1. Evaluasi kapasitas saat wr_start
                if wr_start = '1' then
                    v_free_space := 2048 - to_integer(level_spec);
                    v_req_len    := to_integer(unsigned(wr_len));
                    if v_free_space < v_req_len then
                        reject_latch <= '1';
                        if overflow_reg /= x"FFFF" then
                            overflow_reg <= overflow_reg + 1;
                        end if;
                    else
                        reject_latch <= '0';
                    end if;
                end if;

                -- 2. Penulisan byte spekulatif ke BRAM
                if wr_valid = '1' and reject_latch = '0' then
                    if (w_spec - r_ptr) < 2048 then
                        mem(to_integer(w_spec(10 downto 0))) <= wr_data;
                        w_spec <= w_spec + 1;
                    end if;
                end if;

                -- 3. Jabat tangan Commit & Rollback
                if wr_rollback = '1' then
                    w_spec       <= w_commit;
                    reject_latch <= '0';
                elsif wr_commit = '1' then
                    if reject_latch = '0' then
                        w_commit <= w_spec;
                    else
                        w_spec <= w_commit;
                    end if;
                    reject_latch <= '0';
                end if;

                -- -------------------------------------------------------------
                -- B. SISI PRE-ROLL & PLAYING
                -- -------------------------------------------------------------
                if playing_reg = '0' then
                    if level_committed >= 1024 then
                        playing_reg <= '1';
                    end if;
                end if;

                -- -------------------------------------------------------------
                -- C. LOGIKA SLIP (DRIFT KRISTAL & HISTESIS)
                -- -------------------------------------------------------------
                -- Cooldown timer slip
                if slip_cool_cnt > 0 then
                    slip_cool_cnt <= slip_cool_cnt - 1;
                end if;

                -- Pemantauan Dwell Low Slip (L < 410)
                if playing_reg = '1' and level_committed < 410 then
                    if dwell_low_cnt < DWELL_CYCLES then
                        dwell_low_cnt <= dwell_low_cnt + 1;
                    else
                        slip_low_mode <= '1';
                    end if;
                else
                    dwell_low_cnt <= 0;
                end if;

                -- Histeresis keluar Low Slip (L >= 512)
                if level_committed >= 512 then
                    slip_low_mode <= '0';
                end if;

                -- Pemantauan Dwell High Slip (L > 1638)
                if playing_reg = '1' and level_committed > 1638 then
                    if dwell_high_cnt < DWELL_CYCLES then
                        dwell_high_cnt <= dwell_high_cnt + 1;
                    else
                        slip_high_mode <= '1';
                    end if;
                else
                    dwell_high_cnt <= 0;
                end if;

                -- Histeresis keluar High Slip (L <= 1536)
                if level_committed <= 1536 then
                    slip_high_mode <= '0';
                end if;

                -- -------------------------------------------------------------
                -- D. SISI BACA KE AUDIO_PWM (FWFT & SLIP EXECUTION)
                -- -------------------------------------------------------------
                if rd_req = '1' then
                    if playing_reg = '0' then
                        -- Masih pre-roll: jangan majukan pointer
                        null;
                    elsif level_committed = 0 then
                        -- Underflow: antrean kosong saat diminta
                        if underflow_reg /= x"FFFF" then
                            underflow_reg <= underflow_reg + 1;
                        end if;
                    else
                        -- Eksekusi pembacaan normal atau slip
                        if slip_low_mode = '1' and slip_cool_cnt = 0 then
                            -- Repeat slip: ulangi sampel terakhir tanpa memajukan r_ptr
                            if repeat_reg /= x"FFFF" then
                                repeat_reg <= repeat_reg + 1;
                            end if;
                            slip_cool_cnt <= SLIP_MIN_CYCLES;
                        elsif slip_high_mode = '1' and slip_cool_cnt = 0 and level_committed >= 2 then
                            -- Drop slip: buang satu sampel (pop dua kali: r_ptr + 2)
                            r_ptr <= r_ptr + 2;
                            if drop_reg /= x"FFFF" then
                                drop_reg <= drop_reg + 1;
                            end if;
                            slip_cool_cnt <= SLIP_MIN_CYCLES;
                        else
                            -- Pembacaan normal: pop 1 sampel
                            r_ptr <= r_ptr + 1;
                        end if;
                    end if;
                end if;

                -- Pembacaan sinkron BRAM (Port B)
                bram_dout <= mem(to_integer(r_ptr(10 downto 0)));
            end if;
        end if;
    end process;

    -- Multiplexer keluaran FWFT
    -- Sebelum playing aktif atau saat antrean kosong terkomit, sajikan level hening 0x80
    rd_data <= x"80" when (playing_reg = '0' or level_committed = 0) else bram_dout;

end architecture rtl;
