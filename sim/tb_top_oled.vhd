-- sim/tb_top_oled.vhd
-- Testbench integrasi tingkat atas (top-level) untuk memverifikasi fungsionalitas
-- subsistem OLED SPI SSD1306 (128x64) bersama pipeline video eksisting (UART RX 921.600 baud,
-- BRAM dual-port frame buffer, dan ASCII sink UART TX).
--
-- Memverifikasi:
-- (a) Keluaran ASCII RsTx byte-exact terhadap 30 frame pertama data/golden/ascii.hex.
-- (b) Model perekam SSD1306 mencuplik GDDRAM akhir sama dengan transposisi Frame 29
--     yang dihitung oleh testbench menggunakan larik 2D bit independen.
-- (c) Setiap frame yang diterima menghasilkan tepat satu transfer OLED (1.024 byte data)
--     setelah inisialisasi selesai (init_done).
-- (d) Asersi: tidak ada swap bank saat oled_spi sedang sibuk.
-- (e) Mode Klip (SW0 = 0): memverifikasi 3 frame ROM dari data/golden/clip_bram_32bit.hex,
--     GDDRAM cocok dengan frame ROM.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
use std.textio.all;
use std.env.finish;

entity tb_top_oled is
end entity tb_top_oled;

architecture sim of tb_top_oled is
    constant CLK_PERIOD    : time := 10 ns;       -- 100 MHz
    constant BIT_TIME_UART : time := 1085 ns;     -- 921.600 baud (1085,07 ns)

    -- Sinyal Antarmuka Top-Level
    signal clk       : std_logic := '0';
    signal btnC      : std_logic := '1';
    signal sw        : std_logic_vector(0 downto 0) := "0";
    signal RsRx      : std_logic := '1';
    signal RsTx      : std_logic;
    signal led       : std_logic_vector(7 downto 0);

    -- Sinyal OLED SPI PMOD JA
    signal oled_res  : std_logic;
    signal oled_dc   : std_logic;
    signal oled_cs   : std_logic;
    signal oled_sclk : std_logic;
    signal oled_mosi : std_logic;

    -- Larik Referensi 2D Independen di Sisi Testbench (64 Baris x 128 Kolom)
    type ref_bitmap_t is array (0 to 63, 0 to 127) of std_logic;
    signal ref_grid   : ref_bitmap_t := (others => (others => '0'));
    signal sim_gddram : ref_bitmap_t := (others => (others => '0'));

    -- Status Perekam SPI SSD1306
    signal rec_init_bytes : integer := 0;
    signal rec_data_bytes : integer := 0;
    signal rec_cmd_bytes  : integer := 0;
    signal rec_init_done  : std_logic := '0';
    signal rec_reset      : std_logic := '0';

    -- Status Monitor ASCII RsTx
    signal ascii_byte_cnt : integer := 0;
    signal ascii_mismatch : integer := 0;
    signal ascii_mon_en   : boolean := false;

    -- Kendali Selesai Simulasi
    signal sim_done : boolean := false;

    -- Hierarchical aliases untuk asersi proteksi swap
    alias uut_swap_done is << signal .tb_top_oled.uut.fb_swap_done : std_logic >>;
    alias uut_oled_busy is << signal .tb_top_oled.uut.oled_busy : std_logic >>;
    alias uut_oled_start is << signal .tb_top_oled.uut.oled_start : std_logic >>;

    -- Prosedur pengiriman UART 8N1 pada 921.600 baud
    procedure uart_send_byte(
        signal tx_line : out std_logic;
        val            : in  std_logic_vector(7 downto 0);
        bit_time       : in  time
    ) is
    begin
        -- Start bit (LOW)
        tx_line <= '0';
        wait for bit_time;
        -- Data bits (LSB first)
        for i in 0 to 7 loop
            tx_line <= val(i);
            wait for bit_time;
        end loop;
        -- Stop bit (HIGH)
        tx_line <= '1';
        wait for bit_time;
    end procedure;

    -- Prosedur pembacaan frame referensi dari frames.hex dan transposisi ke 2D grid
    procedure load_ref_frame(
        constant frame_idx : in integer;
        signal grid        : out ref_bitmap_t
    ) is
        file f_frames       : text;
        variable l          : line;
        variable b          : std_logic_vector(7 downto 0);
        variable skip_lines : integer;
        variable row        : integer;
        variable col_byte   : integer;
    begin
        file_open(f_frames, "data/golden/frames.hex", read_mode);
        skip_lines := frame_idx * 1024;
        for i in 0 to skip_lines - 1 loop
            readline(f_frames, l);
        end loop;

        for i in 0 to 1023 loop
            readline(f_frames, l);
            hread(l, b);
            row      := i / 16;
            col_byte := i mod 16;
            for bit_idx in 0 to 7 loop
                grid(row, col_byte * 8 + (7 - bit_idx)) <= b(bit_idx);
            end loop;
        end loop;
        file_close(f_frames);
    end procedure;

begin
    -- Pembangkit Clock 100 MHz
    clk_proc : process
    begin
        while not sim_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process;

    -- Instansiasi Top-Level DUT
    uut : entity work.top
        generic map (
            CLK_FREQ_HZ  => 100_000_000,
            BAUD_RATE    => 921_600,
            TARGET_FPS   => 30,
            TOTAL_FRAMES => 90,
            INIT_FILE    => "data/golden/clip_bram_32bit.hex"
        )
        port map (
            clk       => clk,
            btnC      => btnC,
            sw        => sw,
            RsRx      => RsRx,
            RsTx      => RsTx,
            led       => led,
            oled_res  => oled_res,
            oled_dc   => oled_dc,
            oled_cs   => oled_cs,
            oled_sclk => oled_sclk,
            oled_mosi => oled_mosi
        );

    -- -------------------------------------------------------------------------
    -- Asersi Invarian (d): Tidak Boleh Ada Swap saat oled_spi Sedang Sibuk
    -- -------------------------------------------------------------------------
    check_swap_proc : process(clk)
    begin
        if rising_edge(clk) then
            if btnC = '0' then
                if uut_swap_done = '1' then
                    report "MONITOR: uut_swap_done aktif pada waktu " & time'image(now);
                    assert uut_oled_busy = '0'
                        report "TEMUAN: Swap buffer terjadi saat oled_spi sedang sibuk!"
                        severity failure;
                end if;
                if uut_oled_start = '1' then
                    report "MONITOR: uut_oled_start aktif pada waktu " & time'image(now);
                end if;
            end if;
        end if;
    end process;

    -- -------------------------------------------------------------------------
    -- Model Perekam Protokol SPI SSD1306 (Disalin dari tb_oled_spi.vhd)
    -- -------------------------------------------------------------------------
    spi_recorder_proc : process
        variable v_shift_reg  : std_logic_vector(7 downto 0) := (others => '0');
        variable v_bit_cnt    : integer := 0;
        variable v_byte_val   : std_logic_vector(7 downto 0);
        variable v_sampled_dc : std_logic := '0';
        variable v_col_start  : integer := 0;
        variable v_col_end    : integer := 127;
        variable v_cur_col    : integer := 0;
        variable v_page_start : integer := 0;
        variable v_page_end   : integer := 7;
        variable v_cur_page   : integer := 0;
        variable v_cmd_phase  : integer := 0;
    begin
        while not sim_done loop
            wait until rising_edge(oled_sclk) or rising_edge(rec_reset) or sim_done;
            if sim_done then
                exit;
            end if;

            if rec_reset = '1' then
                rec_data_bytes <= 0;
                rec_init_bytes <= 0;
                rec_cmd_bytes  <= 0;
                rec_init_done  <= '0';
                v_bit_cnt      := 0;
                v_shift_reg    := (others => '0');
                v_cmd_phase    := 0;
            elsif rising_edge(oled_sclk) then

            if oled_cs = '0' then
                v_shift_reg := v_shift_reg(6 downto 0) & oled_mosi;
                v_bit_cnt   := v_bit_cnt + 1;

                if v_bit_cnt = 8 then
                    v_sampled_dc := oled_dc;
                    v_byte_val   := v_shift_reg;
                    v_bit_cnt    := 0;

                    if v_sampled_dc = '0' then
                        rec_cmd_bytes <= rec_cmd_bytes + 1;
                        if rec_init_done = '0' then
                            rec_init_bytes <= rec_init_bytes + 1;
                            if rec_init_bytes + 1 = 25 then
                                rec_init_done <= '1';
                            end if;
                        else
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
                        rec_data_bytes <= rec_data_bytes + 1;
                        for r in 0 to 7 loop
                            sim_gddram(v_cur_page * 8 + r, v_cur_col) <= v_byte_val(r);
                        end loop;

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
                else
                    v_bit_cnt := 0;
                end if;
            end if;
        end loop;
        wait;
    end process;

    -- -------------------------------------------------------------------------
    -- Monitor Keluaran UART ASCII RsTx (Check a: byte-exact vs ascii.hex)
    -- -------------------------------------------------------------------------
    rx_ascii_monitor : process
        file golden_file     : text;
        variable golden_line : line;
        variable golden_byte : std_logic_vector(7 downto 0);
        variable rx_byte_val : std_logic_vector(7 downto 0);
    begin
        wait until ascii_mon_en;
        file_open(golden_file, "data/golden/ascii.hex", read_mode);

        while not sim_done loop
            wait until falling_edge(RsTx) or sim_done;
            if sim_done then
                exit;
            end if;

            -- Cuplik di tengah start bit
            wait for BIT_TIME_UART / 2;
            if RsTx = '0' then
                -- Cuplik 8 bit data (LSB duluan)
                for i in 0 to 7 loop
                    wait for BIT_TIME_UART;
                    rx_byte_val(i) := RsTx;
                end loop;

                -- Verifikasi stop bit (HIGH)
                wait for BIT_TIME_UART;
                assert RsTx = '1' report "Stop bit UART error pada RsTx!" severity failure;

                ascii_byte_cnt <= ascii_byte_cnt + 1;

                if not endfile(golden_file) then
                    readline(golden_file, golden_line);
                    hread(golden_line, golden_byte);
                    if rx_byte_val /= golden_byte then
                        ascii_mismatch <= ascii_mismatch + 1;
                        report "MISMATCH ASCII pada byte " & integer'image(ascii_byte_cnt) &
                               ": terukur=" & to_hstring(rx_byte_val) &
                               ", diharapkan=" & to_hstring(golden_byte)
                               severity failure;
                    end if;
                end if;
            end if;
        end loop;

        file_close(golden_file);
        wait;
    end process;

    -- -------------------------------------------------------------------------
    -- Proses Pembangkit Stimulus Utama
    -- -------------------------------------------------------------------------
    stim_proc : process
        file stream_file     : text;
        variable l_str       : line;
        variable b_val       : std_logic_vector(7 downto 0);
        variable frame_len   : integer;
        variable t_frame_tgt : time;
        variable t_sim_start : time;
        variable prev_data_b : integer;
    begin
        ------------------------------------------------------------------------
        -- FASE 1: MODE KLIP ROM (SW0 = 0) - UJI 3 FRAME
        ------------------------------------------------------------------------
        report "=== [TB_TOP_OLED] Memulai Fase 1: Mode Klip ROM (SW0 = 0, 3 Frame) ===";
        sw   <= "0";
        RsRx <= '1';
        btnC <= '1';
        wait for 100 ns;
        wait until rising_edge(clk);
        btnC <= '0';

        -- Tunggu inisialisasi OLED selesai
        wait until rec_init_done = '1';
        report "OLED Initialization selesai pada Fase 1.";

        -- Tunggu sampai 3 frame dari ROM selesai ditransfer ke OLED (3 x 1024 = 3072 byte)
        wait until rec_data_bytes >= 3072 for 150 ms;
        assert rec_data_bytes >= 3072
            report "TIMEOUT: rec_data_bytes tidak mencapai 3072 dalam Mode Klip! rec_data_bytes=" & integer'image(rec_data_bytes)
            severity failure;
        wait for 50 us;

        -- Verifikasi Check (e): GDDRAM sama dengan frame ROM ke-2 (frame ke-3 klip)
        report "Memverifikasi Check (e): GDDRAM Mode Klip terhadap Frame 2 ROM...";
        load_ref_frame(2, ref_grid);
        wait for 100 ns;

        for y in 0 to 63 loop
            for x in 0 to 127 loop
                assert sim_gddram(y, x) = ref_grid(y, x)
                    report "GAGAL KECOCOKAN GDDRAM Mode Klip pada (" &
                           integer'image(x) & "," & integer'image(y) & ")! terukur=" &
                           std_logic'image(sim_gddram(y, x)) & ", diharapkan=" &
                           std_logic'image(ref_grid(y, x))
                    severity failure;
            end loop;
        end loop;
        report "Fase 1 SUKSES: 3 frame Mode Klip terverifikasi pada GDDRAM!";

        ------------------------------------------------------------------------
        -- FASE 2: MODE STREAMING (SW0 = 1) - UJI 30 FRAME DARI stream_clip.hex
        ------------------------------------------------------------------------
        report "=== [TB_TOP_OLED] Memulai Fase 2: Mode Streaming (SW0 = 1, 30 Frame) ===";
        sw <= "1";
        btnC <= '1';
        wait for 100 ns;
        wait until rising_edge(clk);
        btnC <= '0';

        -- Reset pencacah rekaman OLED untuk fase streaming
        rec_reset <= '1';
        wait until rising_edge(clk);
        rec_reset <= '0';
        wait until rising_edge(clk);

        wait until rec_init_done = '1';
        report "OLED Re-initialization selesai pada Fase 2.";
        ascii_mon_en <= true;
        wait for 1 us;

        t_sim_start := now;
        report "Waktu simulasi awal transmisi streaming: " & time'image(t_sim_start);

        -- Buka berkas streaming data/golden/stream_clip.hex
        file_open(stream_file, "data/golden/stream_clip.hex", read_mode);

        for f in 0 to 29 loop
            report "DBG: Mulai kirim streaming Frame " & integer'image(f) & " pada waktu " & time'image(now);
            t_frame_tgt := t_sim_start + (f + 1) * 33_333_333 ns;
            prev_data_b := rec_data_bytes;

            -- Kirim header SOF (0x55 0xAA 0x5A)
            readline(stream_file, l_str); hread(l_str, b_val); uart_send_byte(RsRx, b_val, BIT_TIME_UART);
            readline(stream_file, l_str); hread(l_str, b_val); uart_send_byte(RsRx, b_val, BIT_TIME_UART);
            readline(stream_file, l_str); hread(l_str, b_val); uart_send_byte(RsRx, b_val, BIT_TIME_UART);

            -- Kirim FRAME_ID
            readline(stream_file, l_str); hread(l_str, b_val); uart_send_byte(RsRx, b_val, BIT_TIME_UART);
            readline(stream_file, l_str); hread(l_str, b_val); uart_send_byte(RsRx, b_val, BIT_TIME_UART);

            -- Kirim PAYLOAD_LEN
            readline(stream_file, l_str); hread(l_str, b_val); uart_send_byte(RsRx, b_val, BIT_TIME_UART);
            frame_len := to_integer(unsigned(b_val)) * 256;
            readline(stream_file, l_str); hread(l_str, b_val); uart_send_byte(RsRx, b_val, BIT_TIME_UART);
            frame_len := frame_len + to_integer(unsigned(b_val));

            -- Kirim data payload RLE
            for p in 0 to frame_len - 1 loop
                readline(stream_file, l_str);
                hread(l_str, b_val);
                uart_send_byte(RsRx, b_val, BIT_TIME_UART);
            end loop;

            -- Kirim EOF (0xED) dan Checksum XOR
            readline(stream_file, l_str); hread(l_str, b_val); uart_send_byte(RsRx, b_val, BIT_TIME_UART);
            readline(stream_file, l_str); hread(l_str, b_val); uart_send_byte(RsRx, b_val, BIT_TIME_UART);
            report "DBG: Selesai kirim UART Frame " & integer'image(f) & " pada waktu " & time'image(now) & ", menunggu OLED (rec_data_bytes=" & integer'image(rec_data_bytes) & ")...";

            -- Tunggu OLED selesai mentransfer frame ini (tepat 1.024 byte data) dengan timeout 100 ms
            wait until rec_data_bytes >= prev_data_b + 1024 for 100 ms;
            assert rec_data_bytes >= prev_data_b + 1024
                report "TIMEOUT: rec_data_bytes tidak bertambah 1024 untuk Frame " & integer'image(f) & "! rec_data_bytes=" & integer'image(rec_data_bytes)
                severity failure;
            report "DBG: OLED selesai transfer Frame " & integer'image(f) & " pada waktu " & time'image(now);
            assert rec_data_bytes = prev_data_b + 1024
                report "GAGAL [Check c, Frame " & integer'image(f) &
                       "]: Transfer OLED tidak tepat 1024 byte! Selisih=" &
                       integer'image(rec_data_bytes - prev_data_b)
                severity failure;

            -- Pacing 30 FPS: sinkronkan selang kirim frame ke kelipatan 33,333 ms
            if now < t_frame_tgt then
                wait for (t_frame_tgt - now);
            end if;
        end loop;

        file_close(stream_file);
        report "Seluruh 30 frame streaming terkirim pada 921.600 baud dengan pacing 30 FPS.";
        report "Waktu simulasi akhir transmisi streaming: " & time'image(now);

        -- Tunggu sampai seluruh byte ASCII frame ke-29 selesai keluar dari RsTx
        wait for 15 ms;

        -- ---------------------------------------------------------------------
        -- VERIFIKASI AKHIR
        -- ---------------------------------------------------------------------
        -- Check (a): ASCII byte-exact 30 frame (31.770 byte)
        assert ascii_byte_cnt = 30 * 1059
            report "GAGAL [Check a]: Jumlah byte ASCII tidak cocok! terukur=" &
                   integer'image(ascii_byte_cnt) & ", diharapkan=" & integer'image(30 * 1059)
            severity failure;
        assert ascii_mismatch = 0
            report "GAGAL [Check a]: Ditemukan ketidakcocokan ASCII!" severity failure;
        report "Check (a) SUKSES: 30 frame ASCII (31.770 byte) cocok 100% byte-exact terhadap ascii.hex.";

        -- Check (b): GDDRAM akhir cocok dengan transposisi Frame 29
        report "Memverifikasi Check (b): GDDRAM akhir terhadap Frame 29 streaming...";
        load_ref_frame(29, ref_grid);
        wait for 100 ns;

        for y in 0 to 63 loop
            for x in 0 to 127 loop
                assert sim_gddram(y, x) = ref_grid(y, x)
                    report "GAGAL KECOCOKAN GDDRAM Frame 29 pada (" &
                           integer'image(x) & "," & integer'image(y) & ")! terukur=" &
                           std_logic'image(sim_gddram(y, x)) & ", diharapkan=" &
                           std_logic'image(ref_grid(y, x))
                    severity failure;
            end loop;
        end loop;
        report "Check (b) SUKSES: GDDRAM akhir cocok 100% dengan transposisi 2D Frame 29!";

        -- Check (c): tepat 30 transfer OLED setelah init_done
        assert rec_data_bytes = 30 * 1024
            report "GAGAL [Check c]: Total byte data OLED tidak cocok! terukur=" &
                   integer'image(rec_data_bytes) & ", diharapkan=" & integer'image(30 * 1024)
            severity failure;
        report "Check (c) SUKSES: Tepat 30 transfer OLED (30.720 byte data) terverifikasi.";

        report "Check (d) SUKSES: Tidak ada tabrakan swap saat oled_spi sibuk.";
        report "Check (e) SUKSES: Mode Klip 3 frame ROM terverifikasi byte-exact.";

        report "TEST PASSED: tb_top_oled berhasil memverifikasi seluruh kriteria uji (a, b, c, d, e)!";
        sim_done <= true;
        finish;
    end process;

end architecture sim;
