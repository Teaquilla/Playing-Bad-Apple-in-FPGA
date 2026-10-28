-- sim/tb_decoder.vhd
-- Testbench untuk decoder memverifikasi perilaku passthrough M1.

library ieee;
use ieee.std_logic_1164.all;

entity tb_decoder is
end entity tb_decoder;

architecture sim of tb_decoder is
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '0';
    signal s_axis_data  : std_logic_vector(7 downto 0) := x"A5";
    signal s_axis_valid : std_logic := '1';
    signal s_axis_last  : std_logic := '1';
    signal s_axis_ready : std_logic;
    signal m_axis_data  : std_logic_vector(7 downto 0);
    signal m_axis_valid : std_logic;
    signal m_axis_last  : std_logic;
    signal m_axis_ready : std_logic := '1';
begin
    uut : entity work.decoder
        port map (
            clk          => clk,
            rst          => rst,
            s_axis_data  => s_axis_data,
            s_axis_valid => s_axis_valid,
            s_axis_last  => s_axis_last,
            s_axis_ready => s_axis_ready,
            m_axis_data  => m_axis_data,
            m_axis_valid => m_axis_valid,
            m_axis_last  => m_axis_last,
            m_axis_ready => m_axis_ready
        );

    stim_proc : process
    begin
        wait for 10 ns;
        assert m_axis_data = x"A5" and m_axis_valid = '1' and m_axis_last = '1' and s_axis_ready = '1'
            report "Decoder passthrough gagal pada uji 1!" severity failure;

        s_axis_data  <= x"3C";
        m_axis_ready <= '0';
        wait for 10 ns;
        assert m_axis_data = x"3C" and s_axis_ready = '0'
            report "Decoder passthrough gagal pada uji 2!" severity failure;

        report "TEST PASSED: decoder passthrough M1 terverifikasi identik." severity note;
        std.env.stop;
    end process;
end architecture sim;
