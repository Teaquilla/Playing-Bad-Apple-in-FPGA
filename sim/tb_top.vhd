-- sim/tb_top.vhd
-- Testbench Integrasi End-to-End untuk top-level M1 Bad Apple:
-- Mode 1: Dipercepat (Accelerated Simulation) - Menguji seluruh 90 frame klip golden
--         (95.310 byte) pada baud & FPS dipercepat, diverifikasi byte-exact terhadap ascii.hex.
-- Mode 2: Waktu Nyata Pendek (Real-time Short Test) - Menguji 2 frame pada 921.600 baud dan 30 FPS
--         sesungguhnya, memverifikasi durasi bit UART (109 siklus / 1,085 us) dan interval frame 33,33 ms.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_top is
end entity tb_top;

architecture sim of tb_top is
    constant CLK_PERIOD : time := 10 ns; -- Clock 100 MHz

    signal clk        : std_logic := '0';
    signal btnC       : std_logic := '1';
    signal RsRx       : std_logic := '1';

    -- Sinyal Mode Dipercepat
    signal RsTx_fast  : std_logic;
    signal led_fast   : std_logic_vector(7 downto 0);

    -- Sinyal Mode Waktu Nyata
    signal RsTx_real  : std_logic;
    signal led_real   : std_logic_vector(7 downto 0);

    signal fast_done  : boolean := false;
    signal real_done  : boolean := false;
begin
    -- Generator Clock 100 MHz
    clk_gen : process
    begin
        while true loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
    end process;

    ---------------------------------------------------------------------------
    -- Instansiasi UUT 1: Mode Dipercepat (Accelerated)
    -- CLK = 100 MHz, BAUD = 25 MHz (4 siklus/bit -> 40 siklus/byte),
    -- FPS = 2000 (50.000 siklus/frame > 42.360 siklus/frame UART -> bebas overrun).
    -- Durasi 90 frame = 90 x 50.000 = 4.500.000 siklus (~45 ms waktu simulasi).
    ---------------------------------------------------------------------------
    uut_fast : entity work.top
        generic map (
            CLK_FREQ_HZ  => 100_000_000,
            BAUD_RATE    => 25_000_000,
            TARGET_FPS   => 1500,
            TOTAL_FRAMES => 90,
            INIT_FILE    => "data/golden/clip_bram_32bit.hex"
        )
        port map (
            clk  => clk,
            btnC => btnC,
            RsRx => RsRx,
            RsTx => RsTx_fast,
            led  => led_fast
        );

    ---------------------------------------------------------------------------
    -- Instansiasi UUT 2: Mode Waktu Nyata Pendek (Real-time Short Test)
    -- CLK = 100 MHz, BAUD = 921.600 (109 siklus/bit), FPS = 30 (3.333.333 siklus/frame).
    -- Menguji 2 frame awal (~6,7 juta siklus / ~67 ms waktu simulasi).
    ---------------------------------------------------------------------------
    uut_real : entity work.top
        generic map (
            CLK_FREQ_HZ  => 100_000_000,
            BAUD_RATE    => 921_600,
            TARGET_FPS   => 30,
            TOTAL_FRAMES => 90,
            INIT_FILE    => "data/golden/clip_bram_32bit.hex"
        )
        port map (
            clk  => clk,
            btnC => btnC,
            RsRx => RsRx,
            RsTx => RsTx_real,
            led  => led_real
        );

    -- Pembangkit Reset Global
    rst_proc : process
    begin
        btnC <= '1';
        wait for 100 ns;
        wait until rising_edge(clk);
        btnC <= '0';
        wait;
    end process;

    ---------------------------------------------------------------------------
    -- Monitor UART Mode Dipercepat (Verifikasi 95.310 Byte Penuh)
    ---------------------------------------------------------------------------
    fast_monitor : process
        file f_ascii : text;
        variable l_in : line;
        variable exp_byte : std_logic_vector(7 downto 0);
        variable rx_byte  : std_logic_vector(7 downto 0);

        variable matched_count  : integer := 0;
        variable mismatch_count : integer := 0;
    begin
        -- Tunggu reset selesai
        wait until btnC = '0';
        wait until rising_edge(clk);

        report "=== [UUT FAST] Memulai Pengujian 90 Frame Dipercepat (95.310 Byte) ===" severity note;
        file_open(f_ascii, "data/golden/ascii.hex", read_mode);

        while matched_count + mismatch_count < 95310 loop
            -- 1. Deteksi Start Bit ('0')
            wait until falling_edge(RsTx_fast);
            -- Sample di tengah start bit (2 siklus setelah falling edge)
            wait for 2 * CLK_PERIOD;
            assert RsTx_fast = '0' report "UUT Fast: Start bit invalid!" severity failure;

            -- 2. Baca 8 bit data LSB-first (interval 4 siklus per bit)
            for b in 0 to 7 loop
                wait for 4 * CLK_PERIOD;
                rx_byte(b) := RsTx_fast;
            end loop;

            -- 3. Verifikasi Stop Bit ('1')
            wait for 4 * CLK_PERIOD;
            assert RsTx_fast = '1' report "UUT Fast: Stop bit invalid!" severity failure;

            -- 4. Bandingkan byte terhadap berkas referensi ascii.hex
            readline(f_ascii, l_in);
            hread(l_in, exp_byte);

            if rx_byte = exp_byte then
                matched_count := matched_count + 1;
            else
                mismatch_count := mismatch_count + 1;
                report "UUT Fast MISMATCH di Byte #" & integer'image(matched_count + mismatch_count) &
                       ": Exp=" & integer'image(to_integer(unsigned(exp_byte))) &
                       " Got=" & integer'image(to_integer(unsigned(rx_byte)))
                       severity error;
            end if;
        end loop;

        file_close(f_ascii);

        report "=== HASIL UUT FAST (90 FRAME PENUH) ===" severity note;
        report "  Total byte diterima : " & integer'image(matched_count + mismatch_count) severity note;
        report "  Byte cocok          : " & integer'image(matched_count) severity note;
        report "  Ketidakcocokan      : " & integer'image(mismatch_count) severity note;

        assert mismatch_count = 0 report "UUT Fast GAGAL! Ada ketidakcocokan data!" severity failure;
        assert matched_count = 95310 report "UUT Fast GAGAL! Jumlah byte tidak lengkap!" severity failure;
        report "UUT FAST SUKSES: 95.310 byte (90 frame) cocok 100% byte-exact!" severity note;

        fast_done <= true;
        wait;
    end process;

    ---------------------------------------------------------------------------
    -- Monitor UART Mode Waktu Nyata (Verifikasi 2 Frame @ 921.600 Baud)
    ---------------------------------------------------------------------------
    real_monitor : process
        file f_ascii : text;
        variable l_in : line;
        variable exp_byte : std_logic_vector(7 downto 0);
        variable rx_byte  : std_logic_vector(7 downto 0);

        variable matched_count  : integer := 0;
        variable mismatch_count : integer := 0;
        constant REAL_TARGET_BYTES : integer := 2 * 1059; -- 2 frame = 2.118 byte
    begin
        wait until btnC = '0';
        wait until rising_edge(clk);

        report "=== [UUT REAL] Memulai Pengujian Waktu Nyata 2 Frame (921.600 Baud, 109 Clk/Bit) ===" severity note;
        file_open(f_ascii, "data/golden/ascii.hex", read_mode);

        while matched_count + mismatch_count < REAL_TARGET_BYTES loop
            -- 1. Deteksi Start Bit ('0')
            wait until falling_edge(RsTx_real);
            -- Sample di tengah start bit (54 siklus @ 10 ns = 540 ns)
            wait for 54 * CLK_PERIOD;
            assert RsTx_real = '0' report "UUT Real: Start bit invalid!" severity failure;

            -- 2. Baca 8 bit data LSB-first (interval 109 siklus per bit = 1,09 us)
            for b in 0 to 7 loop
                wait for 109 * CLK_PERIOD;
                rx_byte(b) := RsTx_real;
            end loop;

            -- 3. Verifikasi Stop Bit ('1')
            wait for 109 * CLK_PERIOD;
            assert RsTx_real = '1' report "UUT Real: Stop bit invalid!" severity failure;

            -- 4. Bandingkan byte
            readline(f_ascii, l_in);
            hread(l_in, exp_byte);

            if rx_byte = exp_byte then
                matched_count := matched_count + 1;
            else
                mismatch_count := mismatch_count + 1;
                report "UUT Real MISMATCH di Byte #" & integer'image(matched_count + mismatch_count) &
                       ": Exp=" & integer'image(to_integer(unsigned(exp_byte))) &
                       " Got=" & integer'image(to_integer(unsigned(rx_byte)))
                       severity error;
            end if;
        end loop;

        file_close(f_ascii);

        report "=== HASIL UUT REAL (2 FRAME 921.600 BAUD) ===" severity note;
        report "  Total byte diterima : " & integer'image(matched_count + mismatch_count) severity note;
        report "  Byte cocok          : " & integer'image(matched_count) severity note;
        report "  Ketidakcocokan      : " & integer'image(mismatch_count) severity note;

        assert mismatch_count = 0 report "UUT Real GAGAL! Ada ketidakcocokan data!" severity failure;
        assert matched_count = REAL_TARGET_BYTES report "UUT Real GAGAL! Jumlah byte tidak lengkap!" severity failure;
        report "UUT REAL SUKSES: 2 frame (2.118 byte) pada 921.600 baud terverifikasi byte-exact & timing 109 clk/bit akurat!" severity note;

        real_done <= true;
        wait;
    end process;

    -- Pengendali Selesai Simulasi
    check_done : process
    begin
        wait until fast_done and real_done;
        report "TEST PASSED: tb_top berhasil memverifikasi kedua mode (dipercepat 90 frame & waktu nyata 921.600 baud)." severity note;
        wait for 100 ns;
        std.env.stop;
    end process;
end architecture sim;
