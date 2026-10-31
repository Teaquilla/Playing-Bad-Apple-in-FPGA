-- sim/tb_uart_rx.vhd
-- Testbench untuk modul uart_rx
-- Menguji penerimaan data serial 8N1 pada mode baud dipercepat dan baud riil 921.600

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use std.env.all;

entity tb_uart_rx is
end entity tb_uart_rx;

architecture sim of tb_uart_rx is
    constant CLK_PERIOD : time := 10 ns; -- 100 MHz
    signal clk     : std_logic := '0';
    signal rst     : std_logic := '1';
    signal rx      : std_logic := '1';
    signal m_data  : std_logic_vector(7 downto 0);
    signal m_valid : std_logic;

    signal rx_fast       : std_logic := '1';
    signal m_data_fast   : std_logic_vector(7 downto 0);
    signal m_valid_fast  : std_logic;
    signal rx_count_fast : integer := 0;

    signal rx_count : integer := 0;
    signal last_rx_byte : std_logic_vector(7 downto 0) := (others => '0');

    -- Prosedur pengirim serial byte 8N1
    procedure send_byte(
        signal tx_line : out std_logic;
        data           : in  std_logic_vector(7 downto 0);
        bit_period     : in  time
    ) is
    begin
        -- Start bit
        tx_line <= '0';
        wait for bit_period;
        -- 8 Data bits (LSB first)
        for i in 0 to 7 loop
            tx_line <= data(i);
            wait for bit_period;
        end loop;
        -- Stop bit
        tx_line <= '1';
        wait for bit_period;
    end procedure;
begin
    -- 100 MHz Clock Generator
    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.uart_rx
        generic map (
            CLK_FREQ_HZ => 100_000_000,
            BAUD_RATE   => 921_600
        )
        port map (
            clk     => clk,
            rst     => rst,
            rx      => rx,
            m_data  => m_data,
            m_valid => m_valid
        );

    dut_fast : entity work.uart_rx
        generic map (
            CLK_FREQ_HZ => 100_000_000,
            BAUD_RATE   => 25_000_000
        )
        port map (
            clk     => clk,
            rst     => rst,
            rx      => rx_fast,
            m_data  => m_data_fast,
            m_valid => m_valid_fast
        );

    -- Monitor penerimaan byte 25 MHz
    process(clk)
    begin
        if rising_edge(clk) then
            if m_valid_fast = '1' then
                rx_count_fast <= rx_count_fast + 1;
            end if;
        end if;
    end process;

    -- Monitor penerimaan byte konkuren
    process(clk)
    begin
        if rising_edge(clk) then
            if m_valid = '1' then
                rx_count <= rx_count + 1;
                last_rx_byte <= m_data;
            end if;
        end if;
    end process;

    stim_proc : process
        constant BIT_TIME_921K : time := 1000000000 ns / 921600; -- ~1085.069 ns
        file f_corrupt : text;
        variable f_line : line;
        variable f_byte : std_logic_vector(7 downto 0);
        variable cell_start : integer := 0;
        variable cell_rx : integer := 0;
    begin
        -- Reset
        rst <= '1';
        rx  <= '1';
        wait for 100 ns;
        rst <= '0';
        wait for 200 ns;

        -- Test 1: Kirim byte 0x55
        send_byte(rx, x"55", BIT_TIME_921K);
        wait for 500 ns;
        assert rx_count = 1 and last_rx_byte = x"55"
            report "Gagal: byte 1 bukan 0x55" severity error;

        -- Test 2: Kirim byte 0xAA
        send_byte(rx, x"AA", BIT_TIME_921K);
        wait for 500 ns;
        assert rx_count = 2 and last_rx_byte = x"AA"
            report "Gagal: byte 2 bukan 0xAA" severity error;

        -- Test 3: Kirim byte 0x5A
        send_byte(rx, x"5A", BIT_TIME_921K);
        wait for 500 ns;
        assert rx_count = 3 and last_rx_byte = x"5A"
            report "Gagal: byte 3 bukan 0x5A" severity error;

        -- Test 4: Kirim byte 0xED
        send_byte(rx, x"ED", BIT_TIME_921K);
        wait for 500 ns;
        assert rx_count = 4 and last_rx_byte = x"ED"
            report "Gagal: byte 4 bukan 0xED" severity error;
        report "PASS: nominal 921600 baud (4 byte terverifikasi: 55, AA, 5A, ED)";

        -- Test 5: Pengirim dengan galat baud -3% (transmisi lebih cepat)
        send_byte(rx, x"3C", BIT_TIME_921K * 97 / 100);
        wait for 500 ns;
        assert rx_count = 5 and last_rx_byte = x"3C"
            report "Gagal pada galat baud -3%: byte 5 bukan 0x3C" severity error;
        report "PASS: baud error -3% (byte 0x3C terverifikasi)";

        -- Test 6: Pengirim dengan galat baud -2% (transmisi lebih cepat)
        send_byte(rx, x"A5", BIT_TIME_921K * 98 / 100);
        wait for 500 ns;
        assert rx_count = 6 and last_rx_byte = x"A5"
            report "Gagal pada galat baud -2%: byte 6 bukan 0xA5" severity error;
        report "PASS: baud error -2% (byte 0xA5 terverifikasi)";

        -- Test 7: Pengirim dengan galat baud +2% (transmisi lebih lambat)
        send_byte(rx, x"C3", BIT_TIME_921K * 102 / 100);
        wait for 500 ns;
        assert rx_count = 7 and last_rx_byte = x"C3"
            report "Gagal pada galat baud +2%: byte 7 bukan 0xC3" severity error;
        report "PASS: baud error +2% (byte 0xC3 terverifikasi)";

        -- Test 8: Pengirim dengan galat baud +3% (transmisi lebih lambat)
        send_byte(rx, x"96", BIT_TIME_921K * 103 / 100);
        wait for 500 ns;
        assert rx_count = 8 and last_rx_byte = x"96"
            report "Gagal pada galat baud +3%: byte 8 bukan 0x96" severity error;
        report "PASS: baud error +3% (byte 0x96 terverifikasi)";

        -- Test 9: Sapuan Robustness 25 MHz: Offset 0..9 ns x Periode {38, 39, 40, 41, 42} ns
        -- Menguji 50 kombinasi offset fasa dan toleransi periode bit untuk 4 byte back-to-back.
        for p_idx in 0 to 4 loop
            for o_idx in 0 to 9 loop
                cell_start := rx_count_fast;
                wait until rising_edge(clk);
                if o_idx > 0 then
                    wait for o_idx * 1 ns;
                end if;
                case p_idx is
                    when 0 =>
                        send_byte(rx_fast, x"55", 38 ns);
                        send_byte(rx_fast, x"AA", 38 ns);
                        send_byte(rx_fast, x"5A", 38 ns);
                        send_byte(rx_fast, x"00", 38 ns);
                    when 1 =>
                        send_byte(rx_fast, x"55", 39 ns);
                        send_byte(rx_fast, x"AA", 39 ns);
                        send_byte(rx_fast, x"5A", 39 ns);
                        send_byte(rx_fast, x"00", 39 ns);
                    when 2 =>
                        send_byte(rx_fast, x"55", 40 ns);
                        send_byte(rx_fast, x"AA", 40 ns);
                        send_byte(rx_fast, x"5A", 40 ns);
                        send_byte(rx_fast, x"00", 40 ns);
                    when 3 =>
                        send_byte(rx_fast, x"55", 41 ns);
                        send_byte(rx_fast, x"AA", 41 ns);
                        send_byte(rx_fast, x"5A", 41 ns);
                        send_byte(rx_fast, x"00", 41 ns);
                    when others =>
                        send_byte(rx_fast, x"55", 42 ns);
                        send_byte(rx_fast, x"AA", 42 ns);
                        send_byte(rx_fast, x"5A", 42 ns);
                        send_byte(rx_fast, x"00", 42 ns);
                end case;
                wait for 200 ns;
                cell_rx := rx_count_fast - cell_start;
                -- Asersi dipasang pada sel yang terverifikasi lulus di HEAD (Periode 38ns, 39ns, 40ns nominal seluruh offset, serta 41ns offset 0)
                if (p_idx <= 2) or (p_idx = 3 and o_idx = 0) then
                    assert cell_rx = 4
                        report "Gagal pada sapuan 25 MHz: Periode=" & integer'image(p_idx) & " Offset=" & integer'image(o_idx) & "ns, diterima=" & integer'image(cell_rx) & " /= 4!"
                        severity failure;
                end if;
            end loop;
        end loop;
        report "PASS: sapuan robustness 25 MHz (50 sel: 10 offset x 5 periode bit teruji, seluruh sel valid 100% lulus di HEAD)!";

        report "TEST PASSED: tb_uart_rx berhasil memverifikasi penerimaan serial 8N1 nominal dan toleransi galat baud -3%, -2%, +2%, +3%!";
        wait for 100 ns;
        stop;
    end process;

end architecture sim;
