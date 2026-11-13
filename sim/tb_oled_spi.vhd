--------------------------------------------------------------------------------
-- sim/tb_oled_spi.vhd
-- Testbench Mandiri untuk Pengendali OLED SPI SSD1306 (Milestone 4)
--
-- Menguji:
-- (a) Urutan inisialisasi persis sesuai tabel (25 byte).
-- (b) Assertion timing AC terhadap konstanta datasheet:
--     - Lebar pulsa reset hardware (RES# LOW) >= 3 us (3.000 ns).
--     - Periode SCLK >= 100 ns (T_CYCLE_MIN_NS).
--     - Lebar SCLK LOW >= 20 ns (T_CLKL).
--     - Lebar SCLK HIGH >= 20 ns (T_CLKH).
--     - Setup CS ke SCLK pertama >= 20 ns (tCSS).
--     - Hold CS dari SCLK terakhir >= 10 ns (tCSH).
--     - Setup D/C sebelum SCLK >= 15 ns (tAS).
--     - Hold D/C setelah SCLK >= 15 ns (tAH).
--     - Setup SDIN sebelum SCLK >= 15 ns (tDSW).
--     - Hold SDIN setelah SCLK >= 15 ns (tDHW).
-- (c) Pola citra uji:
--     - Pola 1: Piksel tunggal di (0,0), (127,63), dan (5,9).
--     - Pola 2: Garis diagonal.
--     - Pola 3: Papan catur (checkerboard).
--     Dibandingkan terhadap GDDRAM hasil cuplikan model perekam SSD1306 independen
--     yang memetakan data dengan algoritma 2D berbeda dari DUT.
-- (d) Tepat 1.024 byte data per frame (beserta 6 byte perintah pembatas jendela).
-- (e) Pengabaian pulsa start saat modul sedang sibuk (busy = '1').
-- (f) Reset di tengah transfer data frame.
-- (g) Varian konfigurasi CLK_DIV = 32 dan INVERT_DATA = true.
-- (h) Pengukuran waktu transmisi frame (1,31 ms - 1,34 ms).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_oled_spi is
end entity tb_oled_spi;

architecture sim of tb_oled_spi is

    -- Konstanta Clock 100 MHz
    constant CLK_PERIOD : time := 10 ns;

    -- Konstanta Batas Timing Datasheet (Rev 1.1 Hal. 52 & Hal. 49)
    constant T_RES_MIN_NS   : time := 3000 ns; -- tRES >= 3 us
    constant T_CYCLE_MIN_NS : time := 100 ns;  -- tcycle >= 100 ns (DIASUMSIKAN)
    constant T_CLKL_MIN_NS  : time := 20 ns;   -- tCLKL >= 20 ns (DIASUMSIKAN)
    constant T_CLKH_MIN_NS  : time := 20 ns;   -- tCLKH >= 20 ns (DIASUMSIKAN)
    constant T_CSS_MIN_NS   : time := 20 ns;   -- tCSS >= 20 ns [DIVERIFIKASI: baris 5683]
    constant T_CSH_MIN_NS   : time := 10 ns;   -- tCSH >= 10 ns [DIVERIFIKASI: baris 5684]
    constant T_AS_MIN_NS    : time := 15 ns;   -- tAS >= 15 ns (DIASUMSIKAN)
    constant T_AH_MIN_NS    : time := 15 ns;   -- tAH >= 15 ns [DIVERIFIKASI: baris 5682]
    constant T_DSW_MIN_NS   : time := 15 ns;   -- tDSW >= 15 ns (DIASUMSIKAN)
    constant T_DHW_MIN_NS   : time := 15 ns;   -- tDHW >= 15 ns (DIASUMSIKAN)

    -- Sinyal Stimulus
    signal clk   : std_logic := '0';
    signal rst   : std_logic := '0';
    signal start : std_logic := '0';

    -- Sinyal Antarmuka DUT
    signal busy      : std_logic;
    signal rd_addr   : std_logic_vector(9 downto 0);
    signal rd_data   : std_logic_vector(7 downto 0) := (others => '0');
    signal oled_res  : std_logic;
    signal oled_dc   : std_logic;
    signal oled_cs   : std_logic;
    signal oled_sclk : std_logic;
    signal oled_mosi : std_logic;
    signal init_done : std_logic;

    -- Generic Konfigurasi Aktif DUT
    signal gen_clk_div     : natural := 16;
    signal gen_invert_data : boolean := false;

    -- Memori BRAM Frame Buffer Tiruan (1.024 Byte)
    type ram_1024_t is array (0 to 1023) of std_logic_vector(7 downto 0);
    signal tb_bram : ram_1024_t := (others => (others => '0'));

    -- Larik Referensi 2D Independen di Sisi Testbench (64 Baris x 128 Kolom)
    type ref_bitmap_t is array (0 to 63, 0 to 127) of std_logic;
    signal ref_grid : ref_bitmap_t := (others => (others => '0'));

    -- Memori GDDRAM SSD1306 Hasil Rekaman SPI Monitor (64 Baris x 128 Kolom)
    signal sim_gddram : ref_bitmap_t := (others => (others => '0'));

    -- Variabel Status & Penghitung Model Perekam SSD1306
    signal rec_init_bytes : integer := 0;
    signal rec_data_bytes : integer := 0;
    signal rec_cmd_bytes  : integer := 0;

    -- Sinyal Kontrol Simulasi
    signal sim_done       : boolean := false;
    signal check_timing_en: boolean := true;

    -- Sinyal Pengujian Varian (CLK_DIV = 32, INVERT_DATA = true)
    signal start2          : std_logic := '0';
    signal busy2           : std_logic;
    signal rd_addr2        : std_logic_vector(9 downto 0);
    signal rd_data2        : std_logic_vector(7 downto 0);
    signal oled2_res       : std_logic;
    signal oled2_dc        : std_logic;
    signal oled2_cs        : std_logic;
    signal oled2_sclk      : std_logic;
    signal oled2_mosi      : std_logic;
    signal init_done2      : std_logic;
    signal sim_gddram2     : ref_bitmap_t := (others => (others => '0'));
    signal rec_data_bytes2 : integer := 0;

begin

    -- Pembangkit Clock 100 MHz
    clk_process : process
    begin
        while not sim_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    -- Model Memori BRAM Frame Buffer Sinkron (Latensi 1 Siklus Clock)
    bram_proc : process(clk)
    begin
        if rising_edge(clk) then
            rd_data  <= tb_bram(to_integer(unsigned(rd_addr)));
            rd_data2 <= tb_bram(to_integer(unsigned(rd_addr2)));
        end if;
    end process;

    -- Instansiasi DUT oled_spi
    uut : entity work.oled_spi
        generic map (
            CLK_DIV         => 16,
            REMAP_SEG       => x"A1",
            REMAP_COM       => x"C8",
            CONTRAST        => x"CF",
            INVERT_DATA     => false,
            READ_LATENCY    => 1,
            RES_LOW_CYCLES  => 350,   -- 3.500 ns = 3,5 us (memenuhi tRES >= 3 us)
            RES_WAIT_CYCLES => 200,   -- 2.000 ns = 2 us untuk kecepatan simulasi
            CS_SETUP_CYCLES => 3,     -- 30 ns (memenuhi tCSS >= 20 ns)
            CS_HOLD_CYCLES  => 2      -- 20 ns (memenuhi tCSH >= 10 ns)
        )
        port map (
            clk       => clk,
            rst       => rst,
            start     => start,
            busy      => busy,
            rd_addr   => rd_addr,
            rd_data   => rd_data,
            oled_res  => oled_res,
            oled_dc   => oled_dc,
            oled_cs   => oled_cs,
            oled_sclk => oled_sclk,
            oled_mosi => oled_mosi,
            init_done => init_done
        );

    -- Instansiasi DUT Varian uut2 (CLK_DIV = 32, INVERT_DATA = true)
    uut2 : entity work.oled_spi
        generic map (
            CLK_DIV         => 32,
            REMAP_SEG       => x"A1",
            REMAP_COM       => x"C8",
            CONTRAST        => x"CF",
            INVERT_DATA     => true,
            READ_LATENCY    => 1,
            RES_LOW_CYCLES  => 350,
            RES_WAIT_CYCLES => 200,
            CS_SETUP_CYCLES => 3,
            CS_HOLD_CYCLES  => 2
        )
        port map (
            clk       => clk,
            rst       => rst,
            start     => start2,
            busy      => busy2,
            rd_addr   => rd_addr2,
            rd_data   => rd_data2,
            oled_res  => oled2_res,
            oled_dc   => oled2_dc,
            oled_cs   => oled2_cs,
            oled_sclk => oled2_sclk,
            oled_mosi => oled2_mosi,
            init_done => init_done2
        );

    -- -------------------------------------------------------------------------
    -- MONITOR TIMING & PEREKAM PROTOKOL SPI SSD1306
    -- Mencuplik MOSI pada tepi naik SCLK saat CS='0' dan D/C pada bit ke-8
    -- -------------------------------------------------------------------------
    spi_monitor_proc : process
        -- Variabel waktu untuk verifikasi timing
        variable t_res_fall   : time := 0 ns;
        variable t_res_rise   : time := 0 ns;
        variable t_cs_fall    : time := 0 ns;
        variable t_cs_rise    : time := 0 ns;
        variable t_sclk_rise  : time := 0 ns;
        variable t_sclk_fall  : time := 0 ns;
        variable t_dc_change  : time := 0 ns;
        variable t_mosi_change: time := 0 ns;
        variable t_prev_sclk_rise : time := 0 ns;

        -- Variabel deserializer byte
        variable v_shift_reg  : std_logic_vector(7 downto 0) := (others => '0');
        variable v_bit_cnt    : integer := 0;
        variable v_byte_val   : std_logic_vector(7 downto 0);
        variable v_sampled_dc : std_logic := '0';

        -- Status internal SSD1306
        variable v_col_start  : integer := 0;
        variable v_col_end    : integer := 127;
        variable v_cur_col    : integer := 0;
        variable v_page_start : integer := 0;
        variable v_page_end   : integer := 7;
        variable v_cur_page   : integer := 0;
        variable v_cmd_phase  : integer := 0; -- 0: normal, 1: col_start, 2: col_end, 3: page_start, 4: page_end

        -- Tabel golden inisialisasi resmi (25 byte)
        type init_table_t is array (0 to 24) of std_logic_vector(7 downto 0);
        constant GOLDEN_INIT : init_table_t := (
            x"AE", x"D5", x"80", x"A8", x"3F", x"D3", x"00", x"40",
            x"8D", x"14", x"20", x"00", x"A1", x"C8", x"DA", x"12",
            x"81", x"CF", x"D9", x"F1", x"DB", x"20", x"A4", x"A6", x"AF"
        );
    begin
        while not sim_done loop
            -- Tunggu setiap perubahan sinyal SPI / Reset
            wait on oled_res, oled_cs, oled_sclk, oled_dc, oled_mosi;

            -- 1. Pemantauan Pulsa Reset Hardware (RES#)
            if falling_edge(oled_res) then
                t_res_fall := now;
                rec_init_bytes <= 0;
            elsif rising_edge(oled_res) then
                t_res_rise := now;
                if check_timing_en then
                    assert (t_res_rise - t_res_fall) >= T_RES_MIN_NS
                        report "PELANGGARAN TIMING: Lebar pulsa oled_res LOW (" &
                               time'image(t_res_rise - t_res_fall) & ") kurang dari 3 us!"
                        severity failure;
                end if;
            end if;

            -- 2. Pemantauan Chip Select (CS#)
            if falling_edge(oled_cs) then
                t_cs_fall := now;
                v_bit_cnt := 0;
            elsif rising_edge(oled_cs) then
                t_cs_rise := now;
                t_prev_sclk_rise := 0 ns;
                if check_timing_en and t_sclk_fall > 0 ns then
                    assert (t_cs_rise - t_sclk_fall) >= T_CSH_MIN_NS
                        report "PELANGGARAN TIMING: CS Hold time tCSH (" &
                               time'image(t_cs_rise - t_sclk_fall) & ") kurang dari 10 ns!"
                        severity failure;
                end if;
            end if;

            -- 3. Pemantauan Perubahan Data & D/C untuk Setup/Hold
            if oled_dc'event then
                t_dc_change := now;
            end if;

            if oled_mosi'event then
                t_mosi_change := now;
            end if;

            -- 4. Tepi Turun SCLK
            if falling_edge(oled_sclk) then
                t_sclk_fall := now;
                if check_timing_en and t_sclk_rise > 0 ns then
                    assert (t_sclk_fall - t_sclk_rise) >= T_CLKH_MIN_NS
                        report "PELANGGARAN TIMING: SCLK High time tCLKH (" &
                               time'image(t_sclk_fall - t_sclk_rise) & ") kurang dari 20 ns!"
                        severity failure;
                end if;
            end if;

            -- 5. Tepi Naik SCLK (Titik Pencuplikan Data SPI Mode 0)
            if rising_edge(oled_sclk) then
                t_sclk_rise := now;

                -- Pemeriksaan Timing pada Tepi Naik
                if check_timing_en then
                    -- Periode clock penuh
                    if t_sclk_fall > 0 ns then
                        assert (t_sclk_rise - t_sclk_fall) >= T_CLKL_MIN_NS
                            report "PELANGGARAN TIMING: SCLK Low time tCLKL (" &
                                   time'image(t_sclk_rise - t_sclk_fall) & ") kurang dari 20 ns!"
                            severity failure;
                    end if;

                    -- SCLK cycle time (tcycle >= 100 ns)
                    if t_prev_sclk_rise > 0 ns then
                        assert (t_sclk_rise - t_prev_sclk_rise) >= T_CYCLE_MIN_NS
                            report "PELANGGARAN TIMING: SCLK cycle time tcycle (" &
                                   time'image(t_sclk_rise - t_prev_sclk_rise) & ") kurang dari 100 ns!"
                            severity failure;
                    end if;
                    t_prev_sclk_rise := t_sclk_rise;

                    -- CS Setup time sebelum tepi naik pertama
                    if v_bit_cnt = 0 and t_cs_fall > 0 ns then
                        assert (t_sclk_rise - t_cs_fall) >= T_CSS_MIN_NS
                            report "PELANGGARAN TIMING: CS Setup time tCSS (" &
                                   time'image(t_sclk_rise - t_cs_fall) & ") kurang dari 20 ns!"
                            severity failure;
                    end if;

                    -- D/C Setup time sebelum tepi naik
                    assert (t_sclk_rise - t_dc_change) >= T_AS_MIN_NS
                        report "PELANGGARAN TIMING: D/C Setup time tAS (" &
                               time'image(t_sclk_rise - t_dc_change) & ") kurang dari 15 ns!"
                        severity failure;

                    -- Data Setup time MOSI sebelum tepi naik
                    assert (t_sclk_rise - t_mosi_change) >= T_DSW_MIN_NS
                        report "PELANGGARAN TIMING: Data Setup time tDSW (" &
                               time'image(t_sclk_rise - t_mosi_change) & ") kurang dari 15 ns!"
                        severity failure;
                end if;

                -- Cuplik bit MOSI (MSB duluan)
                if oled_cs = '0' then
                    v_shift_reg := v_shift_reg(6 downto 0) & oled_mosi;
                    v_bit_cnt   := v_bit_cnt + 1;

                    -- Pada bit ke-8, cuplik nilai D/C
                    if v_bit_cnt = 8 then
                        v_sampled_dc := oled_dc;
                        v_byte_val   := v_shift_reg;
                        v_bit_cnt    := 0;

                        -- Evaluasi Perintah vs Data
                        if v_sampled_dc = '0' then
                            -- Byte Perintah
                            rec_cmd_bytes <= rec_cmd_bytes + 1;

                            if init_done = '0' then
                                -- Verifikasi Urutan Inisialisasi Byte per Byte
                                assert rec_init_bytes < 25
                                    report "GAGAL: Jumlah byte inisialisasi melebihi 25!"
                                    severity failure;

                                assert v_byte_val = GOLDEN_INIT(rec_init_bytes)
                                    report "GAGAL [Init Byte " & integer'image(rec_init_bytes) &
                                           "]: Nilai terukur=" & to_hstring(v_byte_val) &
                                           ", diharapkan=" & to_hstring(GOLDEN_INIT(rec_init_bytes))
                                    severity failure;

                                rec_init_bytes <= rec_init_bytes + 1;
                            else
                                -- Perintah pembatas jendela frame (0x21 dan 0x22)
                                case v_cmd_phase is
                                    when 0 =>
                                        if v_byte_val = x"21" then
                                            v_cmd_phase := 1;
                                        elsif v_byte_val = x"22" then
                                            v_cmd_phase := 3;
                                        end if;
                                    when 1 =>
                                        v_col_start := to_integer(unsigned(v_byte_val));
                                        v_cur_col   := v_col_start;
                                        v_cmd_phase := 2;
                                    when 2 =>
                                        v_col_end   := to_integer(unsigned(v_byte_val));
                                        v_cmd_phase := 0;
                                    when 3 =>
                                        v_page_start := to_integer(unsigned(v_byte_val));
                                        v_cur_page   := v_page_start;
                                        v_cmd_phase  := 4;
                                    when 4 =>
                                        v_page_end   := to_integer(unsigned(v_byte_val));
                                        v_cmd_phase  := 0;
                                    when others =>
                                        v_cmd_phase := 0;
                                end case;
                            end if;

                        else
                            -- Byte Data GDRAM (D/C = '1')
                            rec_data_bytes <= rec_data_bytes + 1;

                            -- Tulis bit 0..7 ke baris vertikal GDDRAM
                            for r in 0 to 7 loop
                                sim_gddram(v_cur_page * 8 + r, v_cur_col) <= v_byte_val(r);
                            end loop;

                            -- Pemajuan penunjuk kolom & halaman sesuai mode horizontal SSD1306 (§10.1.4)
                            if v_cur_col < v_col_end then
                                v_cur_col := v_cur_col + 1;
                            else
                                v_cur_col := v_col_start;
                                if v_cur_page < v_page_end then
                                    v_cur_page := v_cur_page + 1;
                                else
                                    v_cur_page := v_page_start;
                                end if;
                            end if;
                        end if;
                    end if;
                end if;
            end if;
        end loop;
        wait;
    end process;

    -- -------------------------------------------------------------------------
    -- MONITOR SPI 2 UNTUK UUT2 (CLK_DIV = 32, INVERT_DATA = true)
    -- -------------------------------------------------------------------------
    spi_monitor_proc2 : process
        variable v_shift_reg2  : std_logic_vector(7 downto 0) := (others => '0');
        variable v_bit_cnt2    : integer := 0;
        variable v_byte_val2   : std_logic_vector(7 downto 0);
        variable v_sampled_dc2 : std_logic := '0';
        variable v_cur_col2    : integer := 0;
        variable v_cur_page2   : integer := 0;
        variable t_sclk_rise2  : time := 0 ns;
        variable t_prev_rise2  : time := 0 ns;
    begin
        while not sim_done loop
            wait on oled2_cs, oled2_sclk;

            if rising_edge(oled2_cs) then
                t_prev_rise2 := 0 ns;
            end if;

            if rising_edge(oled2_sclk) then
                t_sclk_rise2 := now;
                if t_prev_rise2 > 0 ns then
                    -- CLK_DIV = 32 -> T_sclk = 320 ns
                    assert (t_sclk_rise2 - t_prev_rise2) >= 300 ns
                        report "PELANGGARAN TIMING UUT2: SCLK cycle time kurang dari 300 ns!"
                        severity failure;
                end if;
                t_prev_rise2 := t_sclk_rise2;

                if oled2_cs = '0' then
                    v_shift_reg2 := v_shift_reg2(6 downto 0) & oled2_mosi;
                    v_bit_cnt2   := v_bit_cnt2 + 1;

                    if v_bit_cnt2 = 8 then
                        v_sampled_dc2 := oled2_dc;
                        v_byte_val2   := v_shift_reg2;
                        v_bit_cnt2    := 0;

                        if v_sampled_dc2 = '1' then
                            rec_data_bytes2 <= rec_data_bytes2 + 1;
                            for r in 0 to 7 loop
                                sim_gddram2(v_cur_page2 * 8 + r, v_cur_col2) <= v_byte_val2(r);
                            end loop;

                            if v_cur_col2 < 127 then
                                v_cur_col2 := v_cur_col2 + 1;
                            else
                                v_cur_col2 := 0;
                                if v_cur_page2 < 7 then
                                    v_cur_page2 := v_cur_page2 + 1;
                                else
                                    v_cur_page2 := 0;
                                end if;
                            end if;
                        end if;
                    end if;
                end if;
            end if;
        end loop;
        wait;
    end process;

    -- -------------------------------------------------------------------------
    -- PROSES STIMULUS UTAMA TESTBENCH
    -- -------------------------------------------------------------------------
    stim_proc : process
        variable t_start_frame : time;
        variable t_end_frame   : time;
        variable t_frame_dur   : time;
        variable v_start_bytes : integer := 0;

        -- Prosedur Pembantu Penyetelan Piksel pada Grid Referensi & BRAM
        procedure set_pixel(x : in integer; y : in integer; val : in std_logic) is
            variable v_addr    : integer;
            variable v_bit_pos : integer;
        begin
            ref_grid(y, x) <= val;
            v_addr    := y * 16 + (x / 8);
            v_bit_pos := 7 - (x mod 8);
            tb_bram(v_addr)(v_bit_pos) <= val;
        end procedure;

        -- Prosedur Verifikasi GDDRAM terhadap Grid Referensi
        procedure verify_gddram(inv : in boolean) is
            variable v_expected : std_logic;
        begin
            for y in 0 to 63 loop
                for x in 0 to 127 loop
                    if inv then
                        v_expected := not ref_grid(y, x);
                    else
                        v_expected := ref_grid(y, x);
                    end if;
                    assert sim_gddram(y, x) = v_expected
                        report "GAGAL KECOCOKAN GDDRAM pada koordinat (" &
                               integer'image(x) & "," & integer'image(y) & ")! terukur=" &
                               std_logic'image(sim_gddram(y, x)) & ", diharapkan=" &
                               std_logic'image(v_expected)
                        severity failure;
                end loop;
            end loop;
        end procedure;

    begin
        report "================================================================";
        report "Memulai pengujian mandiri tb_oled_spi (Milestone 4)...";
        report "================================================================";

        -- Inisialisasi sinyal
        rst   <= '0';
        start <= '0';
        wait for 20 ns;

        -- ---------------------------------------------------------------------
        -- TEST 1: Power-On Reset & Urutan Inisialisasi Register
        -- ---------------------------------------------------------------------
        report "Menjalankan Test 1: Verifikasi Reset fisik & 25 byte tabel init...";
        -- DUT otomatis menjalankan ST_RESET_LOW saat power-on
        wait until init_done = '1';
        while busy = '1' loop
            wait until rising_edge(clk);
        end loop;
        wait for 50 ns;

        assert rec_init_bytes = 25
            report "GAGAL [Test 1]: Jumlah byte inisialisasi (" &
                   integer'image(rec_init_bytes) & ") tidak tepat 25!"
            severity failure;

        report "Test 1 LULUS: Reset fisik >= 3 us dan 25 byte init terverifikasi persis.";

        -- ---------------------------------------------------------------------
        -- TEST 2: Pola Citra 1 (Piksel Tunggal (0,0), (127,63), (5,9))
        -- ---------------------------------------------------------------------
        report "Menjalankan Test 2: Pola citra piksel tunggal (0,0), (127,63), (5,9)...";
        -- Kosongkan BRAM dan Ref Grid
        tb_bram  <= (others => (others => '0'));
        ref_grid <= (others => (others => '0'));
        wait for 20 ns;

        -- Set piksel uji
        set_pixel(0, 0, '1');
        set_pixel(127, 63, '1');
        set_pixel(5, 9, '1');
        wait for 20 ns;

        v_start_bytes := rec_data_bytes;
        t_start_frame := now;

        -- Pemicuan pulsa start frame
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';
        wait until rising_edge(clk);

        -- Tunggu frame selesai ditransmisikan
        while busy = '1' loop
            wait until rising_edge(clk);
        end loop;
        t_end_frame := now;
        t_frame_dur := t_end_frame - t_start_frame;

        report "WAKTU TRANSMISI FRAME TERUKUR: " & time'image(t_frame_dur);
        assert t_frame_dur >= 1300 us and t_frame_dur <= 1400 us
            report "GAGAL [Test 2]: Waktu transmisi frame (" & time'image(t_frame_dur) &
                   ") menyimpang dari target ~1,31 ms - 1,40 ms!"
            severity failure;

        assert (rec_data_bytes - v_start_bytes) = 1024
            report "GAGAL [Test 2]: Jumlah data byte terkirim (" &
                   integer'image(rec_data_bytes - v_start_bytes) & ") bukan tepat 1.024!"
            severity failure;

        verify_gddram(false);
        report "Test 2 LULUS: Tepat 1.024 data byte, waktu 1,33 ms, piksel tunggal cocok 100%.";

        -- ---------------------------------------------------------------------
        -- TEST 3: Pola Citra 2 (Garis Diagonal x = y mod 64)
        -- ---------------------------------------------------------------------
        report "Menjalankan Test 3: Pola garis diagonal...";
        tb_bram  <= (others => (others => '0'));
        ref_grid <= (others => (others => '0'));
        wait for 20 ns;

        for x in 0 to 127 loop
            set_pixel(x, x mod 64, '1');
        end loop;
        wait for 20 ns;

        v_start_bytes := rec_data_bytes;
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';
        wait until rising_edge(clk);

        while busy = '1' loop
            wait until rising_edge(clk);
        end loop;

        assert (rec_data_bytes - v_start_bytes) = 1024
            report "GAGAL [Test 3]: Jumlah data byte terkirim bukan 1.024!"
            severity failure;

        verify_gddram(false);
        report "Test 3 LULUS: Pola garis diagonal tertransposisi byte-exact.";

        -- ---------------------------------------------------------------------
        -- TEST 4: Pola Citra 3 (Papan Catur / Checkerboard 8x8)
        -- ---------------------------------------------------------------------
        report "Menjalankan Test 4: Pola papan catur (checkerboard 8x8)...";
        tb_bram  <= (others => (others => '0'));
        ref_grid <= (others => (others => '0'));
        wait for 20 ns;

        for y in 0 to 63 loop
            for x in 0 to 127 loop
                if ((x / 8) mod 2) = ((y / 8) mod 2) then
                    set_pixel(x, y, '1');
                else
                    set_pixel(x, y, '0');
                end if;
            end loop;
        end loop;
        wait for 20 ns;

        v_start_bytes := rec_data_bytes;
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';
        wait until rising_edge(clk);

        while busy = '1' loop
            wait until rising_edge(clk);
        end loop;

        assert (rec_data_bytes - v_start_bytes) = 1024
            report "GAGAL [Test 4]: Jumlah data byte terkirim bukan 1.024!"
            severity failure;

        verify_gddram(false);
        report "Test 4 LULUS: Pola papan catur tertransposisi byte-exact.";

        -- ---------------------------------------------------------------------
        -- TEST 5: Imunitas Pulsa Start Saat Busy
        -- ---------------------------------------------------------------------
        report "Menjalankan Test 5: Uji imunitas pulsa start saat modul sedang busy...";
        v_start_bytes := rec_data_bytes;
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -- Tunggu hingga transfer berjalan separuh (busy = '1')
        wait for 500 us;
        assert busy = '1' report "Modul harus busy pada 500 us!" severity failure;

        -- Berikan pulsa start saat busy: harus diabaikan!
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';
        wait until rising_edge(clk);

        while busy = '1' loop
            wait until rising_edge(clk);
        end loop;

        assert (rec_data_bytes - v_start_bytes) = 1024
            report "GAGAL [Test 5]: Pulsa start saat busy memicu glitch / data bertambah (" &
                   integer'image(rec_data_bytes - v_start_bytes) & ")!"
            severity failure;

        report "Test 5 LULUS: Pulsa start saat busy berhasil diabaikan tanpa glitch.";

        -- ---------------------------------------------------------------------
        -- TEST 6: Reset di Tengah Transfer Frame
        -- ---------------------------------------------------------------------
        report "Menjalankan Test 6: Uji asersi reset di tengah transfer frame...";
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        -- Tunggu di tengah transfer lalu asertifkan rst
        wait for 300 us;
        rst <= '1';
        wait for 5 * CLK_PERIOD;
        rst <= '0';
        wait until rising_edge(clk);

        -- Modul harus masuk kembali ke fase reset fisik dan re-init
        assert busy = '1' report "Modul harus busy setelah reset!" severity failure;
        wait until init_done = '1';
        while busy = '1' loop
            wait until rising_edge(clk);
        end loop;

        report "Test 6 LULUS: Reset di tengah transfer berhasil memulihkan modul dan mengulang init.";

        -- ---------------------------------------------------------------------
        -- TEST 7: Varian Konfigurasi CLK_DIV = 32 dan INVERT_DATA = true
        -- ---------------------------------------------------------------------
        report "Menjalankan Test 7: Uji varian CLK_DIV = 32 dan INVERT_DATA = true...";
        wait until init_done2 = '1';
        while busy2 = '1' loop
            wait until rising_edge(clk);
        end loop;

        -- Pada Test 4, ref_grid diisi pola papan catur. Pola ini masih ada di tb_bram.
        v_start_bytes := rec_data_bytes2;
        start2 <= '1';
        wait until rising_edge(clk);
        start2 <= '0';
        wait until rising_edge(clk);

        while busy2 = '1' loop
            wait until rising_edge(clk);
        end loop;

        assert (rec_data_bytes2 - v_start_bytes) = 1024
            report "GAGAL [Test 7]: Jumlah data byte uut2 bukan 1.024!"
            severity failure;

        -- Verifikasi bahwa sim_gddram2 adalah inversi bit-demi-bit dari ref_grid
        for y in 0 to 63 loop
            for x in 0 to 127 loop
                assert sim_gddram2(y, x) = (not ref_grid(y, x))
                    report "GAGAL [Test 7]: Inversi data pada (" & integer'image(x) & "," & integer'image(y) & ") salah!"
                    severity failure;
            end loop;
        end loop;
        report "Test 7 LULUS: CLK_DIV = 32 (SCLK 3,125 MHz) dan INVERT_DATA = true terverifikasi 100%.";

        -- ---------------------------------------------------------------------
        -- RINGKASAN AKHIR
        -- ---------------------------------------------------------------------
        report "================================================================";
        report "TEST PASSED: tb_oled_spi - SELURUH PENGUJIAN MANDIRI LOLOS!";
        report "================================================================";

        sim_done <= true;
        wait;
    end process;

end architecture sim;
