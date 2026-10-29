-- sim/tb_rle_decoder.vhd
-- Testbench untuk modul rle_decoder
-- Menguji dekompresi RLE per baris ke format kanonik dan deteksi galat run > 128

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_rle_decoder is
end entity tb_rle_decoder;

architecture sim of tb_rle_decoder is
    constant CLK_PERIOD : time := 10 ns;
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';

    signal s_axis_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal s_axis_valid : std_logic := '0';
    signal s_axis_ready : std_logic;
    signal s_axis_last  : std_logic := '0';

    signal m_axis_data  : std_logic_vector(7 downto 0);
    signal m_axis_valid : std_logic;
    signal m_axis_ready : std_logic := '1';
    signal m_axis_last  : std_logic;

    signal frame_done   : std_logic;
    signal err_run      : std_logic;
    signal err_len      : std_logic;

    signal out_byte_count : integer := 0;
begin
    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.rle_decoder
        generic map (
            FRAME_WIDTH  => 128,
            FRAME_HEIGHT => 64,
            TOTAL_BYTES  => 1024
        )
        port map (
            clk          => clk,
            rst          => rst,
            s_axis_data  => s_axis_data,
            s_axis_valid => s_axis_valid,
            s_axis_ready => s_axis_ready,
            s_axis_last  => s_axis_last,
            m_axis_data  => m_axis_data,
            m_axis_valid => m_axis_valid,
            m_axis_ready => m_axis_ready,
            m_axis_last  => m_axis_last,
            frame_done   => frame_done,
            err_run      => err_run,
            err_len      => err_len
        );

    -- Monitor keluaran byte kanonik
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                out_byte_count <= 0;
            elsif m_axis_valid = '1' and m_axis_ready = '1' then
                out_byte_count <= out_byte_count + 1;
            end if;
        end if;
    end process;

    stim_proc : process
        procedure send_run(run : in integer; is_last : in std_logic) is
        begin
            wait until rising_edge(clk) and s_axis_ready = '1';
            s_axis_data  <= std_logic_vector(to_unsigned(run, 8));
            s_axis_valid <= '1';
            s_axis_last  <= is_last;
            wait until rising_edge(clk);
            s_axis_valid <= '0';
            s_axis_last  <= '0';
        end procedure;
    begin
        rst <= '1';
        wait for 50 ns;
        rst <= '0';
        wait for 20 ns;

        -- 1. Uji Frame Hitam Penuh: 64 baris, masing-masing 1 run bernilai 128 (hitam)
        for row in 0 to 63 loop
            if row = 63 then
                send_run(128, '1'); -- Last byte of frame
            else
                send_run(128, '0');
            end if;
        end loop;

        wait until frame_done = '1' for 50 us;
        assert frame_done = '1' report "Gagal: frame_done tidak aktif pada frame valid" severity error;
        assert out_byte_count = 1024 report "Gagal: out_byte_count /= 1024" severity error;

        -- 2. Uji Run Melebihi 128 (Galat)
        wait for 100 ns;
        send_run(150, '0');
        wait until err_run = '1' for 10 us;
        assert err_run = '1' report "Gagal: err_run tidak aktif pada run > 128" severity error;

        report "TEST PASSED: tb_rle_decoder berhasil memverifikasi ekspansi kanonik dan deteksi run overflow!";
        wait for 100 ns;
        stop;
    end process;

end architecture sim;

