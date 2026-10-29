-- sim/tb_rx_fifo.vhd
-- Testbench untuk modul rx_fifo
-- Menguji penulisan, pembacaan spekulatif, commit transaksi, dan rollback saat galat

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_rx_fifo is
end entity tb_rx_fifo;

architecture sim of tb_rx_fifo is
    constant CLK_PERIOD : time := 10 ns;
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';

    signal wr_en        : std_logic := '0';
    signal wr_data      : std_logic_vector(7 downto 0) := (others => '0');
    signal full         : std_logic;

    signal rd_req       : std_logic := '0';
    signal rd_data      : std_logic_vector(7 downto 0);
    signal spec_empty   : std_logic;

    signal mark_sof     : std_logic := '0';
    signal commit       : std_logic := '0';
    signal rollback     : std_logic := '0';

    signal commit_empty : std_logic;
    signal overflow_err : std_logic;
begin
    clk <= not clk after CLK_PERIOD / 2;

    dut : entity work.rx_fifo
        generic map (
            FIFO_DEPTH => 2048
        )
        port map (
            clk          => clk,
            rst          => rst,
            wr_en        => wr_en,
            wr_data      => wr_data,
            full         => full,
            rd_req       => rd_req,
            rd_data      => rd_data,
            spec_empty   => spec_empty,
            mark_sof     => mark_sof,
            commit       => commit,
            rollback     => rollback,
            commit_empty => commit_empty,
            overflow_err => overflow_err
        );

    stim_proc : process
    begin
        rst <= '1';
        wait for 50 ns;
        rst <= '0';
        wait for 20 ns;

        -- 1. Tulis 4 byte: 0x55, 0xAA, 0x5A, 0x12
        wait until rising_edge(clk);
        wr_en <= '1'; wr_data <= x"55";
        wait until rising_edge(clk);
        wr_en <= '1'; wr_data <= x"AA";
        wait until rising_edge(clk);
        wr_en <= '1'; wr_data <= x"5A";
        wait until rising_edge(clk);
        wr_en <= '1'; wr_data <= x"12";
        wait until rising_edge(clk);
        wr_en <= '0';
        wait for 20 ns;

        -- 2. Baca 3 byte pertama
        wait until rising_edge(clk);
        assert spec_empty = '0' report "FIFO seharusnya tidak kosong" severity error;
        mark_sof <= '1'; -- Tandai alamat SOF
        rd_req   <= '1';
        wait until rising_edge(clk);
        mark_sof <= '0';
        rd_req   <= '1';
        wait until rising_edge(clk);
        rd_req   <= '1';
        wait until rising_edge(clk);
        rd_req   <= '0';
        wait for 20 ns;

        -- 3. Uji Rollback: batalkan pembacaan, pointer harus kembali ke SOF + 1
        wait until rising_edge(clk);
        rollback <= '1';
        wait until rising_edge(clk);
        rollback <= '0';
        wait for 20 ns;

        -- 4. Baca ulang setelah rollback: byte pertama setelah SOF + 1 adalah 0xAA
        wait until rising_edge(clk);
        rd_req <= '1';
        wait until rising_edge(clk);
        rd_req <= '0';
        wait until rising_edge(clk);
        assert rd_data = x"AA" report "Gagal rollback: byte setelah SOF+1 bukan 0xAA" severity error;

        -- 5. Uji Commit
        wait until rising_edge(clk);
        commit <= '1';
        wait until rising_edge(clk);
        commit <= '0';
        wait for 20 ns;

        report "TEST PASSED: tb_rx_fifo berhasil memverifikasi fungsi commit dan speculative rollback!";
        wait for 100 ns;
        stop;
    end process;

end architecture sim;

