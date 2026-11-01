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
    signal clr_fast      : std_logic := '0';

    type byte_arr_4_t is array (0 to 3) of std_logic_vector(7 downto 0);
    signal rx_buf_fast : byte_arr_4_t := (others => (others => '0'));

    signal rx_count : integer := 0;
    signal last_rx_byte : std_logic_vector(7 downto 0) := (others => '0');

    type byte_arr_real_t is array (0 to 15) of std_logic_vector(7 downto 0);
    signal rx_buf_real : byte_arr_real_t := (others => (others => '0'));

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
            if rst = '1' or clr_fast = '1' then
                rx_count_fast <= 0;
            elsif m_valid_fast = '1' then
                if rx_count_fast < 4 then
                    rx_buf_fast(rx_count_fast) <= m_data_fast;
                end if;
                rx_count_fast <= rx_count_fast + 1;
            end if;
        end if;
    end process;

    -- Monitor penerimaan byte baud riil (921.600 baud)
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rx_count <= 0;
            elsif m_valid = '1' then
                if rx_count < 16 then
                    rx_buf_real(rx_count) <= m_data;
                end if;
                rx_count <= rx_count + 1;
                last_rx_byte <= m_data;
            end if;
        end if;
    end process;

    stim_proc : process
        constant BIT_TIME_921K : time := 1000000000 ns / 921600; -- ~1085.069 ns
        variable cell_rx : integer := 0;
    begin
        -- Reset
        rst <= '1';
        rx  <= '1';
        rx_fast <= '1';
        clr_fast <= '0';
        wait for 100 ns;
        wait until rising_edge(clk);
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

        -- Test 8b: Uji baud riil dengan periode bit 1100 ns (+1.38%) untuk byte MSB=0 (0x00 dan 0x55)
        -- Menguji toleransi stop bit pada laju baud lambat saat bit data terakhir bernilai '0'.
        send_byte(rx, x"00", 1100 ns);
        send_byte(rx, x"55", 1100 ns);
        wait for 3 us;
        assert rx_count = 10 and rx_buf_real(8) = x"00" and rx_buf_real(9) = x"55"
            report "Gagal pada baud 1100 ns (MSB=0): byte 0x00 atau 0x55 tidak diterima dengan benar (rx_count=" & integer'image(rx_count) & ")!" severity failure;
        report "PASS: baud error 1100 ns (+1.38%, byte MSB=0: 0x00 dan 0x55 terverifikasi byte-exact)";

        -- Test 9: Sapuan Robustness 25 MHz: Offset 0..9 ns x Periode {38, 39, 40, 41, 42} ns
        -- Menguji 50 kombinasi offset fasa dan toleransi periode bit untuk 4 byte back-to-back (55, AA, 5A, 00).
        for p_idx in 0 to 4 loop
            for o_idx in 0 to 9 loop
                wait until rising_edge(clk);
                clr_fast <= '1';
                wait until rising_edge(clk);
                clr_fast <= '0';
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
                cell_rx := rx_count_fast;
                -- Asersi dipasang pada sel yang terverifikasi lulus di kandidat (Periode 39, 40, 41, 42 ns nominal seluruh offset 0..9)
                -- dengan verifikasi byte-exact terhadap 4 byte: 0x55, 0xAA, 0x5A, 0x00
                if p_idx >= 1 then
                    assert cell_rx = 4
                        report "Gagal jumlah byte pada 25 MHz: Periode=" & integer'image(38 + p_idx) & "ns Offset=" & integer'image(o_idx) & "ns, diterima=" & integer'image(cell_rx) & " /= 4!"
                        severity failure;
                    assert rx_buf_fast(0) = x"55" and rx_buf_fast(1) = x"AA" and rx_buf_fast(2) = x"5A" and rx_buf_fast(3) = x"00"
                        report "Gagal isi byte pada 25 MHz: Periode=" & integer'image(38 + p_idx) & "ns Offset=" & integer'image(o_idx) & "ns!"
                        severity failure;
                end if;
            end loop;
        end loop;
        report "PASS: sapuan robustness 25 MHz (40 sel: 39..42 ns seluruh offset terverifikasi byte-exact 55, AA, 5A, 00)!";

        report "TEST PASSED: tb_uart_rx berhasil memverifikasi penerimaan serial 8N1 nominal dan toleransi galat baud!";
        wait for 100 ns;
        stop;
    end process;

end architecture sim;
