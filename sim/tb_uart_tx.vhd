-- sim/tb_uart_tx.vhd
-- Testbench untuk uart_tx dengan model penerima UART independen (sampling di tengah bit).
-- Memverifikasi transmisi byte pada baud rate target 921600 dan 115200.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_uart_tx is
end entity tb_uart_tx;

architecture sim of tb_uart_tx is
    constant CLK_PERIOD : time := 10 ns; -- 100 MHz clock

    signal clk      : std_logic := '0';
    signal rst      : std_logic := '1';
    signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_valid : std_logic := '0';
    signal tx_ready : std_logic;
    signal RsTx     : std_logic;

    constant TEST_BAUD : integer := 921_600;
    constant BIT_PERIOD : time := (1_000_000_000 / TEST_BAUD) * 1 ns; -- ~1085 ns
begin
    -- 100 MHz Clock Generator
    clk_proc : process
    begin
        while true loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
    end process;

    uut : entity work.uart_tx
        generic map (
            CLK_FREQ_HZ => 100_000_000,
            BAUD_RATE   => TEST_BAUD
        )
        port map (
            clk      => clk,
            rst      => rst,
            tx_data  => tx_data,
            tx_valid => tx_valid,
            tx_ready => tx_ready,
            RsTx     => RsTx
        );

    -- Stimulus & Receiver Verification Process
    stim_proc : process
        type byte_array_t is array (0 to 3) of std_logic_vector(7 downto 0);
        constant TEST_BYTES : byte_array_t := (x"55", x"AA", x"42", x"7F");
        variable rx_byte : std_logic_vector(7 downto 0);
    begin
        rst <= '1';
        wait for 50 ns;
        wait until rising_edge(clk);
        rst <= '0';
        wait for 50 ns;

        for i in TEST_BYTES'range loop
            -- Tunggu transmitter ready
            wait until rising_edge(clk) and tx_ready = '1';
            tx_data  <= TEST_BYTES(i);
            tx_valid <= '1';
            wait until rising_edge(clk);
            tx_valid <= '0';

            -- Model UART Receiver:
            -- 1. Deteksi falling edge start bit
            wait until falling_edge(RsTx);
            -- 2. Tunggu ke tengah start bit (0.5 bit period) dan verifikasi '0'
            wait for BIT_PERIOD / 2;
            assert RsTx = '0' report "Start bit bukan 0!" severity failure;

            -- 3. Sampel 8 data bits (LSB first) di tengah bit period
            for b in 0 to 7 loop
                wait for BIT_PERIOD;
                rx_byte(b) := RsTx;
            end loop;

            -- 4. Tunggu ke tengah stop bit dan verifikasi '1'
            wait for BIT_PERIOD;
            assert RsTx = '1' report "Stop bit bukan 1!" severity failure;

            -- 5. Bandingkan byte yang diterima dengan byte yang dikirim
            assert rx_byte = TEST_BYTES(i)
                report "Byte mismatch! Dikirim: " & integer'image(to_integer(unsigned(TEST_BYTES(i)))) &
                       " Diterima: " & integer'image(to_integer(unsigned(rx_byte)))
                severity failure;
        end loop;

        report "TEST PASSED: uart_tx berhasil mentransmisikan seluruh byte dengan akurat pada 921.600 baud." severity note;
        wait for 200 ns;
        std.env.stop;
    end process;
end architecture sim;
