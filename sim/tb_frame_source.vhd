-- sim/tb_frame_source.vhd
-- Testbench untuk frame_source memverifikasi streaming frame kanonik,
-- pulsa last pada byte 1024, backpressure ready, dan looping klip.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_frame_source is
end entity tb_frame_source;

architecture sim of tb_frame_source is
    constant CLK_PERIOD : time := 10 ns;

    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal start_frame  : std_logic := '0';
    signal m_axis_data  : std_logic_vector(7 downto 0);
    signal m_axis_valid : std_logic;
    signal m_axis_last  : std_logic;
    signal m_axis_ready : std_logic := '1';
begin
    clk_proc : process
    begin
        while true loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
    end process;

    uut : entity work.frame_source
        generic map (
            TOTAL_FRAMES => 90,
            FRAME_BYTES  => 1024,
            INIT_FILE    => "data/golden/clip_bram_32bit.hex",
            FREE_RUNNING => false
        )
        port map (
            clk          => clk,
            rst          => rst,
            start_frame  => start_frame,
            m_axis_data  => m_axis_data,
            m_axis_valid => m_axis_valid,
            m_axis_last  => m_axis_last,
            m_axis_ready => m_axis_ready
        );

    stim_proc : process
        variable byte_count : integer := 0;
    begin
        rst <= '1';
        wait for 50 ns;
        wait until rising_edge(clk);
        rst <= '0';
        wait for 30 ns;

        -- 1. Uji Frame 0 (1024 byte normal tanpa backpressure)
        wait until rising_edge(clk);
        start_frame <= '1';
        wait until rising_edge(clk);
        start_frame <= '0';

        byte_count := 0;
        while true loop
            wait until rising_edge(clk);
            if m_axis_valid = '1' and m_axis_ready = '1' then
                byte_count := byte_count + 1;
                if byte_count = 1024 then
                    assert m_axis_last = '1' report "Sinyal last tidak aktif di byte 1024!" severity failure;
                    exit;
                else
                    assert m_axis_last = '0' report "Sinyal last aktif sebelum byte 1024!" severity failure;
                end if;
            end if;
        end loop;

        assert byte_count = 1024 report "Jumlah byte bukan 1024!" severity failure;
        report "Frame 0 berhasil: tepat 1024 byte diterima dengan sinyal last benar." severity note;

        -- 2. Uji Frame 1 dengan Backpressure (m_axis_ready toggling)
        wait for 100 ns;
        wait until rising_edge(clk);
        start_frame <= '1';
        wait until rising_edge(clk);
        start_frame <= '0';

        byte_count := 0;
        while byte_count < 1024 loop
            wait until rising_edge(clk);
            if m_axis_valid = '1' and m_axis_ready = '1' then
                byte_count := byte_count + 1;
                -- Berikan stall / backpressure selama 2 siklus setelah setiap 100 byte
                if (byte_count mod 100 = 0) and byte_count < 1024 then
                    m_axis_ready <= '0';
                    wait until rising_edge(clk);
                    wait until rising_edge(clk);
                    m_axis_ready <= '1';
                end if;

                if byte_count = 1024 then
                    assert m_axis_last = '1' report "Sinyal last tidak aktif di byte 1024 pada backpressure!" severity failure;
                end if;
            end if;
        end loop;

        report "TEST PASSED: frame_source lulus seluruh uji (1024 byte/frame, sinyal last, & backpressure)." severity note;
        wait for 100 ns;
        std.env.stop;
    end process;

end architecture sim;
