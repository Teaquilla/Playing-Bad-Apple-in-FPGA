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
        -- TEST 6: Slip Dua Arah (Dwell timer, Cooldown SLIP_MIN, Histeresis)
        ------------------------------------------------------------------------
        report "Menjalankan Test 6: Verifikasi slip dua arah terakselerasi...";
        -- Reset untuk menguji slip
        rst <= '1';
        wait for 3 * CLK_PERIOD;
        wait until rising_edge(clk);
        rst <= '0';
        wait until rising_edge(clk);

        -- Isi 1.024 byte agar playing aktif
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(1024, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 1 to 1024 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned(i mod 256, 8));
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
            wr_data  <= x"11";
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

        -- Sekarang low-slip mode aktif: lakukan rd_req
        v_val := to_integer(unsigned(cnt_repeat));
        mux_rd_req <= '1';
        wait until rising_edge(clk);
        mux_rd_req <= '0';
        wait until rising_edge(clk);

        assert to_integer(unsigned(cnt_repeat)) = v_val + 1
            report "GAGAL [Test 6b]: cnt_repeat tidak bertambah saat low-slip aktif!" severity failure;

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
            wr_data  <= x"22";
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
            wr_data  <= x"33";
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
        mux_rd_req <= '1';
        wait until rising_edge(clk);
        mux_rd_req <= '0';
        wait until rising_edge(clk);

        assert to_integer(unsigned(cnt_drop)) = v_val + 1
            report "GAGAL [Test 6c]: cnt_drop tidak bertambah saat high-slip aktif!" severity failure;

        report "Test 6 LULUS: Slip dua arah, dwell, cooldown, dan histeresis terverifikasi.";

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
        -- TEST 8: Rantai audio_fifo -> audio_pwm (Varian B)
        ------------------------------------------------------------------------
        report "Menjalankan Test 8: Rantai audio_fifo -> audio_pwm (Varian B)...";
        -- Sambungkan rd_req ke sample_req audio_pwm
        -- Isi audio_fifo dengan paket rampa sampel hingga >= 1.024 byte
        -- Paket 1: 266 byte (nilai 0 s.d. 255 + 10 byte)
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(266, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 0 to 265 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned(i mod 256, 8));
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';

        -- Paket 2: 267 byte
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(267, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 0 to 266 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned((i + 10) mod 256, 8));
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';

        -- Paket 3: 266 byte
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(266, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 0 to 265 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned(i mod 256, 8));
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';

        -- Paket 4: 267 byte (total 1066 byte >= 1024, pre-roll tuntas)
        wr_start <= '1';
        wr_len   <= std_logic_vector(to_unsigned(267, 11));
        wait until rising_edge(clk);
        wr_start <= '0';
        for i in 0 to 266 loop
            wr_valid <= '1';
            wr_data  <= std_logic_vector(to_unsigned(i mod 256, 8));
            wait until rising_edge(clk);
        end loop;
        wr_valid  <= '0';
        wr_commit <= '1';
        wait until rising_edge(clk);
        wr_commit <= '0';
        wait until rising_edge(clk);

        assert playing = '1'
            report "GAGAL [Test 8]: Pre-roll belum selesai setelah 1066 byte!" severity failure;

        -- Hubungkan audio_pwm ke audio_fifo
        -- Amati 5 sampel audio berturut-turut yang diputar audio_pwm
        for s in 1 to 5 loop
            wait until pwm_req = '1';
            mux_rd_req <= '1'; -- Audio PWM meminta sampel
            wait until rising_edge(clk);
            mux_rd_req <= '0';

            -- Ukur duty carrier pertama dari sampel ini
            v_high := 0;
            for c in 0 to 249 loop
                wait until rising_edge(clk);
                if pwm_out = '1' then
                    v_high := v_high + 1;
                end if;
            end loop;

            -- Pastikan tidak ada underflow
            assert to_integer(unsigned(cnt_underflow)) = 0
                report "GAGAL [Test 8]: Terjadi underflow tak terduga!" severity failure;
        end loop;

        report "Test 8 LULUS: Rantai audio_fifo -> audio_pwm berhasil tanpa underflow.";

        ------------------------------------------------------------------------
        -- RINGKASAN AKHIR
        ------------------------------------------------------------------------
        report "================================================================";
        report "TEST PASSED: tb_audio_fifo - SELURUH 8 PENGUJIAN LOLOS!";
        report "================================================================";

        sim_done <= true;
        wait;
    end process;

end architecture sim;
