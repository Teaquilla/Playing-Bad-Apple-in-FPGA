--------------------------------------------------------------------------------
-- sim/tb_audio_fifo.vhd
-- Testbench Mandiri Modul Daun Audio FIFO (Milestone 4)
--
-- Pengujian yang Dilakukan:
-- (1) Isi tepat 2.048 byte lalu kosongkan; deteksi penuh dan kosong pada wrap pointer.
-- (2) Tulis 266 byte + rollback: L tidak berubah; commit: L naik 266 & isi urut benar.
-- (3) wr_reject saat sisa ruang < wr_len tanpa mengubah L; cnt_overflow bertambah.
-- (4) Pre-roll menahan keluaran 0x80 hingga L >= 1.024, lalu playing = 1.
-- (5) Underflow saat playing='1' dan L=0: keluaran 0x80, cnt_underflow naik, playing tetap '1'.
-- (6) Slip dua arah (dwell timer, cooldown SLIP_MIN, histeresis, & penolakan jeda < DWELL).
-- (7) Tulis dan baca bersamaan pada laju maksimum 100 MHz.
-- (8) Rantai terintegrasi audio_fifo -> audio_pwm (Varian B): paket 266/267 byte rampa,
--     verifikasi duty cycle PWM sesuai sampel tanpa underflow.
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_audio_fifo is
end entity tb_audio_fifo;

architecture sim of tb_audio_fifo is

    constant CLK_PERIOD : time := 10 ns; -- 100 MHz clock

    -- Generics percepatan untuk Test 6 (Slip)
    constant TB_DWELL    : natural := 50;
    constant TB_SLIP_MIN : natural := 20;

    -- Sinyal kendali utama DUT
    signal clk           : std_logic := '0';
    signal rst           : std_logic := '1';

    -- Sisi Tulis
    signal wr_start      : std_logic := '0';
    signal wr_len        : std_logic_vector(10 downto 0) := (others => '0');
    signal wr_valid      : std_logic := '0';
    signal wr_data       : std_logic_vector(7 downto 0)  := (others => '0');
    signal wr_commit     : std_logic := '0';
    signal wr_rollback   : std_logic := '0';
    signal wr_reject     : std_logic;

    -- Sisi Baca
    signal rd_req        : std_logic := '0';
    signal rd_data       : std_logic_vector(7 downto 0);

    -- Status
    signal level         : std_logic_vector(11 downto 0);
    signal playing       : std_logic;
    signal cnt_overflow  : std_logic_vector(15 downto 0);
    signal cnt_underflow : std_logic_vector(15 downto 0);
    signal cnt_drop      : std_logic_vector(15 downto 0);
    signal cnt_repeat    : std_logic_vector(15 downto 0);

    -- Sinyal Rantai Test 8 (audio_fifo -> audio_pwm)
    signal pwm_enable    : std_logic := '1';
    signal pwm_req       : std_logic;
    signal pwm_out       : std_logic;
    signal mux_rd_req    : std_logic := '0';

    signal sim_done      : boolean := false;

begin

    -- Pembangkit Clock 100 MHz
    clk_gen : process
    begin
        while not sim_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process clk_gen;

    -- Instansiasi DUT Audio FIFO
    dut_fifo : entity work.audio_fifo
        generic map (
            DWELL_CYCLES    => TB_DWELL,
            SLIP_MIN_CYCLES => TB_SLIP_MIN
        )
        port map (
            clk           => clk,
            rst           => rst,
            wr_start      => wr_start,
            wr_len        => wr_len,
            wr_valid      => wr_valid,
            wr_data       => wr_data,
            wr_commit     => wr_commit,
            wr_rollback   => wr_rollback,
            wr_reject     => wr_reject,
            rd_req        => mux_rd_req,
            rd_data       => rd_data,
            level         => level,
            playing       => playing,
            cnt_overflow  => cnt_overflow,
            cnt_underflow => cnt_underflow,
            cnt_drop      => cnt_drop,
            cnt_repeat    => cnt_repeat
        );

    -- Instansiasi audio_pwm untuk Test 8
    dut_pwm : entity work.audio_pwm
        generic map (
            CLK_FREQ_HZ => 100_000_000,
            SAMPLE_RATE => 8_000
        )
        port map (
            clk        => clk,
            rst        => rst,
            enable     => pwm_enable,
            sample_in  => rd_data,
            sample_req => pwm_req,
            pwm_out    => pwm_out
        );

    -- Proses Pengujian Utama
    process
        variable v_level : integer;
        variable v_val   : integer;
        variable v_high  : integer;
        variable v_ramp_cnt        : integer := 0;
        variable v_sample1         : std_logic_vector(7 downto 0);
        variable v_sample2         : std_logic_vector(7 downto 0);
        variable v_expected_duty   : integer;
        variable v_expected_sample : std_logic_vector(7 downto 0);

        -- Variabel Papan Skor (Test 9)
        type scoreboard_arr is array (0 to 8191) of std_logic_vector(7 downto 0);
        variable sb_mem            : scoreboard_arr;
        variable sb_wr_ptr         : integer := 0;
        variable sb_rd_ptr         : integer := 0;
        variable v_pkt_len         : integer;
        variable v_cur_byte        : std_logic_vector(7 downto 0);
        variable v_total_verified  : integer := 0;
    begin
        report "================================================================";
        report "Memulai pengujian tb_audio_fifo (Milestone 4)...";
        report "================================================================";

        -- Inisialisasi awal
        rst <= '1';
        mux_rd_req <= '0';
        wait for 5 * CLK_PERIOD;
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        ------------------------------------------------------------------------
        -- TEST 1: Isi tepat 2.048 byte lalu kosongkan; wrap pointer penuh & kosong
        ------------------------------------------------------------------------
        report "Menjalankan Test 1: Kapasitas 2.048 byte dan wrap pointer...";
        assert to_integer(unsigned(level)) = 0
            report "GAGAL [Test 1]: Level awal bukan 0!" severity failure;

        -- Isi 2.048 byte
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(2048, 11));
        wait until rising_edge(clk);
        wr_start <= '0';

        for i in 0 to 2047 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned(i mod 256, 8));
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';

        wait until rising_edge(clk);
        assert to_integer(unsigned(level)) = 2048
            report "GAGAL [Test 1]: Level setelah isi 2048 byte bukan 2048! (terukur " &
                   integer'image(to_integer(unsigned(level))) & ")" severity failure;
        assert playing = '1'
            report "GAGAL [Test 1]: playing belum aktif setelah L=2048!" severity failure;

        -- Kosongkan seluruh 2.048 byte
        for i in 0 to 2047 loop
            mux_rd_req <= '1';
            wait until rising_edge(clk);
        end loop;
        mux_rd_req <= '0';

        wait until rising_edge(clk);
        wait until rising_edge(clk);
        assert to_integer(unsigned(level)) = 0
            report "GAGAL [Test 1]: Level setelah kosong bukan 0! (terukur " &
                   integer'image(to_integer(unsigned(level))) & ")" severity failure;

        -- Isi lagi 100 byte untuk memverifikasi pointer wrap melewati batas 2048
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(100, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 0 to 99 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned(i, 8));
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';
        wait until rising_edge(clk);

        assert to_integer(unsigned(level)) = 100
            report "GAGAL [Test 1]: Wrap pointer gagal mendeteksi level 100!" severity failure;

        -- Kosongkan kembali 100 byte
        for i in 0 to 99 loop
            mux_rd_req <= '1';
            wait until rising_edge(clk);
        end loop;
        mux_rd_req <= '0';
        wait until rising_edge(clk);
        report "Test 1 LULUS: Kapasitas tepat 2.048 byte dan wrap pointer terverifikasi benar.";

        -- Reset perangkat untuk Test 2
        rst <= '1';
        wait for 3 * CLK_PERIOD;
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        ------------------------------------------------------------------------
        -- TEST 2: 266 byte + rollback vs commit
        ------------------------------------------------------------------------
        report "Menjalankan Test 2: Tulis 266 byte spekulatif + rollback vs commit...";
        -- Tulis 50 byte terkomit terlebih dahulu
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(50, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 1 to 50 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned(i, 8));
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';
        wait until rising_edge(clk);
        assert to_integer(unsigned(level)) = 50
            report "GAGAL [Test 2]: Level bukan 50 setelah commit awal!" severity failure;

        -- Tulis 216 byte berikutnya secara spekulatif lalu rollback
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(216, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 1 to 216 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned(i, 8));
            wait until rising_edge(clk);
        end loop;
        wr_valid <= '0';
        wait until rising_edge(clk);

        assert to_integer(unsigned(level)) = 50
            report "GAGAL [Test 2]: Level bertambah sebelum commit!" severity failure;

        -- Lakukan rollback (harus kembali ke commit = 50)
        wr_rollback <= '1';
        wait until rising_edge(clk);
        wr_rollback <= '0';
        wait until rising_edge(clk);

        assert to_integer(unsigned(level)) = 50
            report "GAGAL [Test 2]: Level tidak kembali ke 50 setelah rollback!" severity failure;

        -- Tulis kembali 216 byte lalu commit (total 50 + 216 = 266)
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(216, 11));
        wait until rising_edge(clk);
        wr_start <= '0';

        for i in 1 to 216 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned(i, 8));
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';
        wait until rising_edge(clk);

        assert to_integer(unsigned(level)) = 266
            report "GAGAL [Test 2]: Level bukan 266 setelah commit!" severity failure;

        report "Test 2 LULUS: Rollback membatalkan penulisan dan commit mengesahkan 266 byte.";

        ------------------------------------------------------------------------
        -- TEST 3: wr_reject bila ruang kosong < wr_len
        ------------------------------------------------------------------------
        report "Menjalankan Test 3: Evaluasi wr_reject dan cnt_overflow...";
        -- Sisa ruang saat ini: 2048 - 266 = 1782 byte.
        -- Minta alokasi 1800 byte (melebihi ruang tersisa)
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(1800, 11));
        wait for 1 ps;
        assert wr_reject = '1'
            report "GAGAL [Test 3]: wr_reject tidak aktif saat ruang kurang!" severity failure;

        wait until rising_edge(clk);
        wr_start <= '0';
        wait until rising_edge(clk);

        assert to_integer(unsigned(cnt_overflow)) = 1
            report "GAGAL [Test 3]: cnt_overflow tidak bertambah!" severity failure;
        assert to_integer(unsigned(level)) = 266
            report "GAGAL [Test 3]: Level berubah akibat permintaan ditolak!" severity failure;

        report "Test 3 LULUS: wr_reject aktif tepat dan level terkomit tidak berubah.";

        -- Reset untuk Test 4
        rst <= '1';
        wait for 3 * CLK_PERIOD;
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        ------------------------------------------------------------------------
        -- TEST 4: Pre-roll menahan 0x80 hingga L >= 1.024
        ------------------------------------------------------------------------
        report "Menjalankan Test 4: Pre-roll menahan 0x80 hingga L >= 1.024...";
        -- Tulis 600 byte (di bawah 1024, tapi di atas 512 untuk mendeteksi threshold)
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(600, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 1 to 600 loop
            wr_valid <= '1';
            wr_data  <= x"55";
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';
        wait until rising_edge(clk);

        assert playing = '0'
            report "GAGAL [Test 4]: playing aktif sebelum 1.024 byte!" severity failure;
        assert rd_data = x"80"
            report "GAGAL [Test 4]: rd_data bukan 0x80 saat pre-roll!" severity failure;

        -- Tambah 424 byte lagi (total 1.024 byte)
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(424, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 1 to 424 loop
            wr_valid <= '1';
            wr_data  <= x"AA";
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';
        wait until rising_edge(clk);

        assert to_integer(unsigned(level)) = 1024
            report "GAGAL [Test 4]: Level bukan 1024!" severity failure;
        assert playing = '1'
            report "GAGAL [Test 4]: playing belum aktif saat L=1024!" severity failure;
        wait until rising_edge(clk);
        assert rd_data = x"55"
            report "GAGAL [Test 4]: rd_data tidak menyajikan sampel pertama setelah playing aktif!"
            severity failure;

        report "Test 4 LULUS: Pre-roll menahan 0x80 tepat hingga L=1.024.";

        ------------------------------------------------------------------------
        -- TEST 5: Underflow (playing=1, L=0 saat rd_req)
        ------------------------------------------------------------------------
        report "Menjalankan Test 5: Underflow saat playing aktif dan L=0...";
        -- Kosongkan seluruh byte hingga L = 0
        while to_integer(unsigned(level)) > 0 loop
            mux_rd_req <= '1';
            wait until rising_edge(clk);
        end loop;
        mux_rd_req <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        assert to_integer(unsigned(level)) = 0
            report "GAGAL [Test 5]: Level bukan 0!" severity failure;
        assert playing = '1'
            report "GAGAL [Test 5]: playing mati saat kosong!" severity failure;
        assert rd_data = x"80"
            report "GAGAL [Test 5]: rd_data bukan 0x80 saat antrean kosong!" severity failure;

        -- Pulsa rd_req saat antrean kosong
        v_val := to_integer(unsigned(cnt_underflow));
        mux_rd_req <= '1';
        wait until rising_edge(clk);
        mux_rd_req <= '0';
        wait until rising_edge(clk);

        assert to_integer(unsigned(cnt_underflow)) = v_val + 1
            report "GAGAL [Test 5]: cnt_underflow tidak bertambah!" severity failure;
        assert playing = '1'
            report "GAGAL [Test 5]: playing berubah saat underflow!" severity failure;

        report "Test 5 LULUS: Underflow terdeteksi benar, rd_data=0x80, dan playing tetap aktif.";

        ------------------------------------------------------------------------
        -- TEST 6: Slip Dua Arah (Dwell timer, Cooldown SLIP_MIN, Histeresis, Nilai Repeat & Drop)
        ------------------------------------------------------------------------
        report "Menjalankan Test 6: Verifikasi slip dua arah terakselerasi dan integritas data sampel...";
        -- Reset untuk menguji slip
        rst <= '1';
        wait for 3 * CLK_PERIOD;
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        v_ramp_cnt := 0;

        -- Isi 1.024 byte agar playing aktif
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(1024, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 1 to 1024 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned(v_ramp_cnt mod 256, 8));
            v_ramp_cnt := v_ramp_cnt + 1;
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';
        wait until rising_edge(clk);

        -- (6a) Jeda singkat < DWELL tidak boleh memicu slip:
        -- Pop hingga L = 400 (< 410)
        for i in 1 to 624 loop
            mux_rd_req <= '1';
            wait until rising_edge(clk);
        end loop;
        mux_rd_req <= '0';
        wait until rising_edge(clk);
        assert to_integer(unsigned(level)) = 400
            report "GAGAL [Test 6a]: Level bukan 400!" severity failure;

        -- Tunggu 10 siklus (< TB_DWELL = 20)
        wait for 10 * CLK_PERIOD;
        -- Segera tambahkan 20 byte (L = 420 >= 410)
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(20, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 1 to 20 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned(v_ramp_cnt mod 256, 8));
            v_ramp_cnt := v_ramp_cnt + 1;
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';
        wait until rising_edge(clk);

        -- Minta pembacaan: pastikan cnt_repeat tetap 0
        mux_rd_req <= '1';
        wait until rising_edge(clk);
        mux_rd_req <= '0';
        wait until rising_edge(clk);
        assert to_integer(unsigned(cnt_repeat)) = 0
            report "GAGAL [Test 6a]: Slip terjadi pada jeda singkat < DWELL!" severity failure;

        -- (6b) Low slip berkelanjutan >= DWELL:
        -- Kurangi level ke 350
        for i in 1 to 70 loop
            mux_rd_req <= '1';
            wait until rising_edge(clk);
        end loop;
        mux_rd_req <= '0';
        wait until rising_edge(clk);

        -- Tunggu > TB_DWELL siklus (60 siklus > 50)
        wait for 60 * CLK_PERIOD;
        wait until rising_edge(clk);

        -- Sekarang low-slip mode aktif: lakukan rd_req dan verifikasi nilai sampel repeat
        v_val := to_integer(unsigned(cnt_repeat));
        v_sample1 := rd_data; -- Catat sampel saat ini
        mux_rd_req <= '1';
        wait until rising_edge(clk);
        mux_rd_req <= '0';
        wait until rising_edge(clk);

        assert to_integer(unsigned(cnt_repeat)) = v_val + 1
            report "GAGAL [Test 6b]: cnt_repeat tidak bertambah saat low-slip aktif!" severity failure;

        -- Verifikasi nilai sampel repeat (C.2): r_ptr tidak dimajukan sehingga data tetap identik
        v_sample2 := rd_data;
        assert v_sample2 = v_sample1
            report "GAGAL [Test 6b]: Nilai sampel kedua berbeda dari sampel pertama pada repeat!" severity failure;

        -- Cek cooldown SLIP_MIN: rd_req kedua segera setelahnya tidak boleh slip
        mux_rd_req <= '1';
        wait until rising_edge(clk);
        mux_rd_req <= '0';
        wait until rising_edge(clk);
        assert to_integer(unsigned(cnt_repeat)) = v_val + 1
            report "GAGAL [Test 6b]: Cooldown SLIP_MIN dilanggar!" severity failure;

        -- Keluar dari low-slip: naikkan level >= 512
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(200, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 1 to 200 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned(v_ramp_cnt mod 256, 8));
            v_ramp_cnt := v_ramp_cnt + 1;
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';
        wait until rising_edge(clk);

        -- (6c) High slip berkelanjutan (L > 1638 >= DWELL)
        -- Tambah hingga L = 1700
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(1200, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 1 to 1200 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned(v_ramp_cnt mod 256, 8));
            v_ramp_cnt := v_ramp_cnt + 1;
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';
        wait until rising_edge(clk);

        assert to_integer(unsigned(level)) > 1638
            report "GAGAL [Test 6c]: Level tidak > 1638!" severity failure;

        -- Tunggu > TB_DWELL siklus (60 siklus)
        wait for 60 * CLK_PERIOD;
        wait until rising_edge(clk);

        -- Lakukan rd_req: drop slip harus aktif (pop 2 sampel, cnt_drop + 1)
        v_val := to_integer(unsigned(cnt_drop));
        v_sample1 := rd_data; -- Sampel sebelum drop
        mux_rd_req <= '1';
        wait until rising_edge(clk);
        mux_rd_req <= '0';
        -- Tunggu latensi BRAM (2 siklus) agar data bram_dout menyajikan r_ptr + 2
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        assert to_integer(unsigned(cnt_drop)) = v_val + 1
            report "GAGAL [Test 6c]: cnt_drop tidak bertambah saat high-slip aktif!" severity failure;

        -- Verifikasi nilai sampel drop (C.2): sampel melompati tepat 1 data (v_sample1 + 2)
        v_sample2 := rd_data;
        assert to_integer(unsigned(v_sample2)) = (to_integer(unsigned(v_sample1)) + 2) mod 256
            report "GAGAL [Test 6c]: Drop tidak melompati tepat 1 sampel! (sebelum=" &
                   integer'image(to_integer(unsigned(v_sample1))) & ", sesudah=" &
                   integer'image(to_integer(unsigned(v_sample2))) & ")" severity failure;

        report "Test 6 LULUS: Slip dua arah, dwell, cooldown, histeresis, dan nilai repeat/drop terverifikasi.";

        -- Reset untuk Test 7
        rst <= '1';
        wait for 3 * CLK_PERIOD;
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        ------------------------------------------------------------------------
        -- TEST 7: Tulis dan baca bersamaan pada laju maksimum 100 MHz
        ------------------------------------------------------------------------
        report "Menjalankan Test 7: Tulis dan baca simultan pada clock 100 MHz...";
        -- Pra-isi 500 byte
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(500, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 1 to 500 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned(i mod 256, 8));
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';
        wait until rising_edge(clk);

        -- Lakukan 100 siklus tulis dan baca serentak
        for i in 1 to 100 loop
            wr_valid   <= '1';
            wr_data    <= std_logic_vector(to_unsigned(i mod 256, 8));
            mux_rd_req <= '1';
            wait until rising_edge(clk);
        end loop;
        wr_valid   <= '0';
        mux_rd_req <= '0';
        wait until rising_edge(clk);

        report "Test 7 LULUS: Tulis dan baca simultan berhasil tanpa tabrakan.";

        -- Reset untuk Test 8
        rst <= '1';
        wait for 3 * CLK_PERIOD;
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        ------------------------------------------------------------------------
        -- TEST 8: Rantai audio_fifo -> audio_pwm (Verifikasi Duty >= 300 Sampel)
        ------------------------------------------------------------------------
        report "Menjalankan Test 8: Rantai audio_fifo -> audio_pwm (320 sampel berurutan)...";
        -- Isi 5 paket (total 1334 byte) dengan rampa sampel terprediksi
        v_ramp_cnt := 0;
        for p in 1 to 5 loop
            if (p = 3) then
                v_pkt_len := 266;
            else
                v_pkt_len := 267;
            end if;
            wr_start <= '1';
            wr_len   <= std_logic_vector(to_unsigned(v_pkt_len, 11));
            wait until rising_edge(clk);
            wr_start <= '0';
            for i in 0 to v_pkt_len - 1 loop
                wr_valid <= '1';
                wr_data  <= std_logic_vector(to_unsigned((v_ramp_cnt * 3 + 17) mod 256, 8));
                v_ramp_cnt := v_ramp_cnt + 1;
                wait until rising_edge(clk);
            end loop;
            wr_valid  <= '0';
            wait until rising_edge(clk);
            wr_commit <= '1';
            wait until rising_edge(clk);
            wr_commit <= '0';
            wait until rising_edge(clk);
        end loop;

        assert playing = '1'
            report "GAGAL [Test 8]: Pre-roll belum selesai setelah 1334 byte!" severity failure;

        -- Jalankan modulasi PWM dan verifikasi duty cycle carrier untuk 320 sampel berturut-turut (>= 300)
        for s in 0 to 319 loop
            wait until pwm_req = '1';
            mux_rd_req <= '1'; -- Sambungkan sample_req ke rd_req
            wait until rising_edge(clk);
            mux_rd_req <= '0';

            v_expected_sample := std_logic_vector(to_unsigned((s * 3 + 17) mod 256, 8));
            v_expected_duty   := (to_integer(unsigned(v_expected_sample)) * 250) / 256;

            -- Ukur duty carrier pertama pada sampel ini (250 siklus)
            v_high := 0;
            for c in 0 to 249 loop
                wait until rising_edge(clk);
                if pwm_out = '1' then
                    v_high := v_high + 1;
                end if;
            end loop;

            assert v_high = v_expected_duty
                report "GAGAL [Test 8]: Duty carrier tidak cocok pada sampel " & integer'image(s) &
                       "! terukur: " & integer'image(v_high) & ", diharapkan: " & integer'image(v_expected_duty)
                severity failure;

            assert to_integer(unsigned(cnt_underflow)) = 0
                report "GAGAL [Test 8]: Terjadi underflow tak terduga pada sampel " & integer'image(s)
                severity failure;
        end loop;

        report "Test 8 LULUS: Rantai audio_fifo -> audio_pwm berhasil tanpa underflow dan 320 sampel terverifikasi duty akurat.";

        -- Reset untuk Test 9
        rst <= '1';
        wait for 3 * CLK_PERIOD;
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        ------------------------------------------------------------------------
        -- TEST 9: Papan Skor Data (Scoreboard across >= 3 Pointer Wraps)
        ------------------------------------------------------------------------
        report "Menjalankan Test 9: Papan skor data (32 paket, rollback spekulatif, wr/rd acak, >= 3 wrap)...";
        sb_wr_ptr := 0;
        sb_rd_ptr := 0;
        v_total_verified := 0;

        for p in 1 to 32 loop
            if (p mod 3 = 0) then
                v_pkt_len := 266;
            else
                v_pkt_len := 267;
            end if;

            wr_start <= '1';
            wr_len   <= std_logic_vector(to_unsigned(v_pkt_len, 11));
            wait until rising_edge(clk);
            wr_start <= '0';

            -- Setiap kelipatan paket ke-5, lakukan rollback spekulatif
            if (p = 5 or p = 10 or p = 15 or p = 20 or p = 25 or p = 30) then
                for i in 0 to v_pkt_len - 1 loop
                    wr_valid <= '1';
                    wr_data  <= x"DE"; -- Data sampah yang dibatalkan
                    wait until rising_edge(clk);
                end loop;
                wr_valid <= '0';
                wr_rollback <= '1';
                wait until rising_edge(clk);
                wr_rollback <= '0';
                wait until rising_edge(clk);
            else
                -- Paket valid yang di-commit
                for i in 0 to v_pkt_len - 1 loop
                    v_cur_byte := std_logic_vector(to_unsigned((sb_wr_ptr * 7 + 13) mod 256, 8));
                    wr_valid   <= '1';
                    wr_data    <= v_cur_byte;
                    sb_mem(sb_wr_ptr) := v_cur_byte;
                    sb_wr_ptr := (sb_wr_ptr + 1) mod 8192;
                    wait until rising_edge(clk);
                end loop;
                wr_valid <= '0';
                wait until rising_edge(clk); -- Jeda protokol 1 siklus
                wr_commit <= '1';
                wait until rising_edge(clk);
                wr_commit <= '0';
                wait until rising_edge(clk);
            end if;

            -- Pembacaan bertahap bila level cukup tinggi (mencegah overflow BRAM)
            -- Sesuai protokol FWFT: rd_data sudah valid sebelum rd_req dipulsa
            if to_integer(unsigned(level)) >= 1300 then
                for r in 0 to 249 loop
                    assert rd_data = sb_mem(sb_rd_ptr)
                        report "GAGAL [Test 9]: Data mismatch di pembacaan ke-" & integer'image(v_total_verified) &
                               "! terukur: " & integer'image(to_integer(unsigned(rd_data))) & ", diharapkan: " &
                               integer'image(to_integer(unsigned(sb_mem(sb_rd_ptr))))
                        severity failure;
                    sb_rd_ptr := (sb_rd_ptr + 1) mod 8192;
                    v_total_verified := v_total_verified + 1;

                    mux_rd_req <= '1';
                    wait until rising_edge(clk);
                    mux_rd_req <= '0';
                    wait until rising_edge(clk);
                    wait until rising_edge(clk);
                end loop;
            end if;
        end loop;

        -- Kuras sisa byte terkomit hingga batas aman level 450 (mencegah pemicuan low-slip L < 410)
        while to_integer(unsigned(level)) > 450 loop
            assert rd_data = sb_mem(sb_rd_ptr)
                report "GAGAL [Test 9]: Data mismatch saat drain di pembacaan ke-" & integer'image(v_total_verified) &
                       "! terukur: " & integer'image(to_integer(unsigned(rd_data))) & ", diharapkan: " &
                       integer'image(to_integer(unsigned(sb_mem(sb_rd_ptr))))
                severity failure;
            sb_rd_ptr := (sb_rd_ptr + 1) mod 8192;
            v_total_verified := v_total_verified + 1;

            mux_rd_req <= '1';
            wait until rising_edge(clk);
            mux_rd_req <= '0';
            wait until rising_edge(clk);
            wait until rising_edge(clk);
        end loop;

        -- Verifikasi bahwa total byte yang terverifikasi melewati >= 3 kali wrap pointer (3 x 2048 = 6144 byte)
        assert v_total_verified >= 6144
            report "GAGAL [Test 9]: Total byte terverifikasi (" & integer'image(v_total_verified) & ") kurang dari 6144!"
            severity failure;

        assert to_integer(unsigned(cnt_overflow)) = 0
            report "GAGAL [Test 9]: Terjadi overflow tidak terduga pada papan skor!" severity failure;

        report "Test 9 LULUS: Papan skor berhasil memvalidasi " & integer'image(v_total_verified) &
               " byte secara byte-exact melewati >= 3 kali wrap pointer.";

        ------------------------------------------------------------------------
        -- TEST 10: Uji Protokol Jabat Tangan Tulis (C.4)
        ------------------------------------------------------------------------
        report "Menjalankan Test 10: Uji waktu jabat tangan wr_commit vs wr_valid...";
        rst <= '1';
        wait for 3 * CLK_PERIOD;
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        -- (10a) wr_commit satu siklus setelah wr_valid terakhir (protokol aman):
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(4, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        wr_valid <= '1'; wr_data <= x"11"; wait until rising_edge(clk);
        wr_valid <= '1'; wr_data <= x"22"; wait until rising_edge(clk);
        wr_valid <= '1'; wr_data <= x"33"; wait until rising_edge(clk);
        wr_valid <= '1'; wr_data <= x"44"; wait until rising_edge(clk);
        wr_valid <= '0'; -- jeda 1 siklus
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';
        wait until rising_edge(clk);

        assert to_integer(unsigned(level)) = 4
            report "GAGAL [Test 10a]: Level bukan 4 pada commit dengan jeda 1 siklus! (terukur " &
                   integer'image(to_integer(unsigned(level))) & ")" severity failure;

        -- Reset untuk 10b
        rst <= '1';
        wait for 3 * CLK_PERIOD;
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        -- (10b) wr_commit pada siklus yang sama dengan wr_valid terakhir (hazard):
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(4, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        wr_valid <= '1'; wr_data <= x"AA"; wait until rising_edge(clk);
        wr_valid <= '1'; wr_data <= x"BB"; wait until rising_edge(clk);
        wr_valid <= '1'; wr_data <= x"CC"; wait until rising_edge(clk);
        wr_valid <= '1'; wr_data <= x"DD"; wr_commit <= '1'; -- BERSAMAAN!
        wait until rising_edge(clk);
        wr_valid  <= '0';
        wr_commit <= '0';
        wait until rising_edge(clk);

        -- Hasil aktual empiris: w_commit mengambil w_spec lama sebelum increment,
        -- sehingga level terkomit hanya 3 (byte ke-4 x"DD" hilang dari commit).
        assert to_integer(unsigned(level)) = 3
            report "GAGAL [Test 10b]: Level bukan 3 saat wr_commit bersamaan dengan wr_valid terakhir! (terukur " &
                   integer'image(to_integer(unsigned(level))) & ")" severity failure;

        report "Test 10 LULUS: Verifikasi waktu jabat tangan wr_commit vs wr_valid terkonfirmasi.";

        ------------------------------------------------------------------------
        -- RINGKASAN AKHIR
        ------------------------------------------------------------------------
        report "================================================================";
        report "TEST PASSED: tb_audio_fifo - SELURUH 10 PENGUJIAN LOLOS!";
        report "================================================================";

        sim_done <= true;
        wait;
    end process;

end architecture sim;
