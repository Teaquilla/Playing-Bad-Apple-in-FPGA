-- sim/tb_top_funcsim.vhd
-- Testbench untuk verifikasi fungsional pasca-sintesis (funcsim)
-- Menguji netlist hasil sintesis top_funcsim.vhd pada mode dipercepat (25 MHz baud, 1500 FPS)
-- Membandingkan seluruh 90 frame (95.310 byte) byte-exact terhadap data/golden/ascii.hex

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_top_funcsim is
end entity tb_top_funcsim;

architecture sim of tb_top_funcsim is
    constant CLK_PERIOD : time := 10 ns; -- 100 MHz
    constant TOTAL_BYTES : integer := 95310;

    signal clk   : std_logic := '0';
    signal btnC  : std_logic := '1';
    signal RsRx  : std_logic := '1';
    signal RsTx  : std_logic;
    signal led   : std_logic_vector(3 downto 0);

    signal sim_done : boolean := false;
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

    -- UUT: Netlist Pasca-Sintesis (top)
    uut : entity work.top
        port map (
            clk  => clk,
            btnC => btnC,
            RsRx => RsRx,
            RsTx => RsTx,
            led  => led
        );

    -- Pembangkit Reset
    rst_proc : process
    begin
        btnC <= '1';
        wait for 100 ns;
        wait until rising_edge(clk);
        btnC <= '0';
        wait;
    end process;

    -- Monitor Verifikasi UART Pasca-Sintesis
    monitor_proc : process
        file f_ascii : text;
        variable l_in : line;
        variable exp_byte : std_logic_vector(7 downto 0);
        variable rx_byte  : std_logic_vector(7 downto 0);

        variable matched_count  : integer := 0;
        variable mismatch_count : integer := 0;
    begin
        wait until btnC = '0';
        wait until rising_edge(clk);

        report "=== [POST-SYNTHESIS FUNCSIM] Memulai Verifikasi 90 Frame (95.310 Byte) ===" severity note;
        file_open(f_ascii, "data/golden/ascii.hex", read_mode);

        while (matched_count + mismatch_count < TOTAL_BYTES) loop
            -- 1. Deteksi Start Bit ('0')
            wait until falling_edge(RsTx);
            -- Sample di tengah start bit (2 siklus @ 10 ns = 20 ns pada baud 25 MHz = 4 siklus/bit)
            wait for 2 * CLK_PERIOD;
            assert RsTx = '0' report "Funcsim: Start bit invalid!" severity failure;

            -- 2. Baca 8 bit data LSB-first (interval 4 siklus per bit)
            for b in 0 to 7 loop
                wait for 4 * CLK_PERIOD;
                rx_byte(b) := RsTx;
            end loop;

            -- 3. Verifikasi Stop Bit ('1')
            wait for 4 * CLK_PERIOD;
            assert RsTx = '1' report "Funcsim: Stop bit invalid!" severity failure;

            -- 4. Bandingkan byte terhadap data golden
            readline(f_ascii, l_in);
            hread(l_in, exp_byte);

            if rx_byte = exp_byte then
                matched_count := matched_count + 1;
            else
                mismatch_count := mismatch_count + 1;
                report "Funcsim MISMATCH di Byte #" & integer'image(matched_count + mismatch_count) &
                       ": Exp=" & integer'image(to_integer(unsigned(exp_byte))) &
                       " Got=" & integer'image(to_integer(unsigned(rx_byte)))
                       severity error;
            end if;

            -- Laporan kemajuan berkala tiap 10 frame (10.590 byte)
            if (matched_count + mismatch_count) mod 10590 = 0 then
                report "Progress Funcsim: " & integer'image(matched_count + mismatch_count) &
                       " / " & integer'image(TOTAL_BYTES) & " byte (" &
                       integer'image((matched_count + mismatch_count) / 1059) & " frame) terverifikasi..."
                       severity note;
            end if;
        end loop;

        file_close(f_ascii);

        report "=== HASIL VERIFIKASI FUNCSIM PASCA-SINTESIS ===" severity note;
        report "  Total byte dibandingkan : " & integer'image(matched_count + mismatch_count) severity note;
        report "  Byte cocok               : " & integer'image(matched_count) severity note;
        report "  Ketidakcocokan           : " & integer'image(mismatch_count) severity note;

        assert mismatch_count = 0 report "Funcsim GAGAL! Ada ketidakcocokan data!" severity failure;
        assert matched_count = TOTAL_BYTES report "Funcsim GAGAL! Jumlah byte tidak lengkap!" severity failure;
        report "TEST PASSED: tb_top_funcsim berhasil memverifikasi seluruh 90 frame (95.310 byte) byte-exact pada netlist pasca-sintesis!" severity note;

        sim_done <= true;
        wait for 100 ns;
        std.env.stop;
    end process;
end architecture sim;
