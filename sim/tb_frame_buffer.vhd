-- sim/tb_frame_buffer.vhd
-- Testbench untuk frame_buffer memverifikasi double-buffering ping-pong,
-- proteksi tearing, deteksi underrun, dan deteksi overrun.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_frame_buffer is
end entity tb_frame_buffer;

architecture sim of tb_frame_buffer is
    constant CLK_PERIOD : time := 10 ns;

    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal swap_req     : std_logic := '0';
    signal read_busy    : std_logic := '0';
    signal overrun      : std_logic;
    signal underrun     : std_logic;
    signal s_axis_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal s_axis_valid : std_logic := '0';
    signal s_axis_ready : std_logic;
    signal s_axis_last  : std_logic := '0';
    signal rd_addr      : unsigned(9 downto 0) := (others => '0');
    signal rd_data      : std_logic_vector(7 downto 0);
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

    uut : entity work.frame_buffer
        generic map (
            FRAME_BYTES => 1024
        )
        port map (
            clk          => clk,
            rst          => rst,
            swap_req     => swap_req,
            read_busy    => read_busy,
            overrun      => overrun,
            underrun     => underrun,
            s_axis_data  => s_axis_data,
            s_axis_valid => s_axis_valid,
            s_axis_ready => s_axis_ready,
            s_axis_last  => s_axis_last,
            rd_addr      => rd_addr,
            rd_data      => rd_data
        );

    stim_proc : process
    begin
        rst <= '1';
        wait for 50 ns;
        wait until rising_edge(clk);
        rst <= '0';
        wait for 20 ns;

        -- 1. Uji Underrun: minta swap sebelum ada data ditulis
        wait until rising_edge(clk);
        swap_req <= '1';
        wait until rising_edge(clk);
        swap_req <= '0';
        wait until rising_edge(clk);
        assert underrun = '1' report "Underrun gagal terdeteksi!" severity failure;
        report "Uji 1 Sukses: Underrun terdeteksi saat bank belakang belum siap." severity note;

        -- 2. Tulis 1024 byte frame 0 (pola byte = index mod 256)
        for i in 0 to 1023 loop
            wait until rising_edge(clk);
            s_axis_valid <= '1';
            s_axis_data  <= std_logic_vector(to_unsigned(i mod 256, 8));
            if i = 1023 then
                s_axis_last <= '1';
            else
                s_axis_last <= '0';
            end if;
        end loop;
        wait until rising_edge(clk);
        s_axis_valid <= '0';
        s_axis_last  <= '0';
        wait for 1 ps; -- Tunggu propagasi delta cycle

        -- Verifikasi back buffer penuh (s_axis_ready harus 0)
        assert s_axis_ready = '0' report "s_axis_ready tidak men-stall setelah frame lengkap!" severity failure;


        -- 3. Eksekusi Swap Valid (read_busy = 0)
        wait until rising_edge(clk);
        swap_req <= '1';
        wait until rising_edge(clk);
        swap_req <= '0';
        wait until rising_edge(clk);
        assert underrun = '0' and overrun = '0' report "Error flag aktif pada swap valid!" severity failure;

        -- 4. Baca Bank Depan dan Verifikasi Integritas Data
        for i in 0 to 1023 loop
            rd_addr <= to_unsigned(i, 10);
            wait until rising_edge(clk);
            wait until rising_edge(clk); -- Synchronous BRAM read latency
            assert rd_data = std_logic_vector(to_unsigned(i mod 256, 8))
                report "Data mismatch di bank depan!" severity failure;
        end loop;
        report "Uji 2 Sukses: Bank depan membaca 1024 byte bit-exact." severity note;

        -- 5. Tulis Frame 1 ke Bank Belakang baru
        for i in 0 to 1023 loop
            wait until rising_edge(clk);
            s_axis_valid <= '1';
            s_axis_data  <= std_logic_vector(to_unsigned((i + 10) mod 256, 8));
            if i = 1023 then
                s_axis_last <= '1';
            else
                s_axis_last <= '0';
            end if;
        end loop;
        wait until rising_edge(clk);
        s_axis_valid <= '0';
        s_axis_last  <= '0';

        -- 6. Uji Overrun: Sink masih membaca (read_busy = 1), swap diminta
        read_busy <= '1';
        wait until rising_edge(clk);
        swap_req <= '1';
        wait until rising_edge(clk);
        swap_req <= '0';
        wait until rising_edge(clk);
        assert overrun = '1' report "Overrun gagal terdeteksi saat read_busy = 1!" severity failure;
        report "Uji 3 Sukses: Overrun terdeteksi, swap ditolak saat sink sibuk." severity note;

        -- 7. Selesaikan pembacaan sink (read_busy = 0), lalu swap ulang
        read_busy <= '0';
        wait until rising_edge(clk);
        swap_req <= '1';
        wait until rising_edge(clk);
        swap_req <= '0';
        wait until rising_edge(clk);
        assert overrun = '0' report "Overrun tidak di-reset setelah swap berhasil!" severity failure;

        report "TEST PASSED: frame_buffer lolos seluruh uji proteksi swap, underrun, dan overrun." severity note;
        wait for 50 ns;
        std.env.stop;
    end process;
end architecture sim;
