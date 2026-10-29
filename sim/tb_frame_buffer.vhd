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

    signal clk            : std_logic := '0';
    signal rst            : std_logic := '1';
    signal streaming_mode : std_logic := '0';
    signal swap_req       : std_logic := '0';
    signal read_busy      : std_logic := '0';
    signal overrun        : std_logic;
    signal underrun       : std_logic;
    signal stream_valid   : std_logic := '0';
    signal stream_drop    : std_logic := '0';
    signal stream_overrun : std_logic;
    signal s_axis_data    : std_logic_vector(7 downto 0) := (others => '0');
    signal s_axis_valid   : std_logic := '0';
    signal s_axis_ready   : std_logic;
    signal s_axis_last    : std_logic := '0';
    signal rd_addr        : unsigned(9 downto 0) := (others => '0');
    signal rd_data        : std_logic_vector(7 downto 0);
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
            clk            => clk,
            rst            => rst,
            streaming_mode => streaming_mode,
            swap_req       => swap_req,
            read_busy      => read_busy,
            overrun        => overrun,
            underrun       => underrun,
            stream_valid   => stream_valid,
            stream_drop    => stream_drop,
            stream_overrun => stream_overrun,
            s_axis_data    => s_axis_data,
            s_axis_valid   => s_axis_valid,
            s_axis_ready   => s_axis_ready,
            s_axis_last    => s_axis_last,
            rd_addr        => rd_addr,
            rd_data        => rd_data
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

        -- =====================================================================
        -- PENGUJIAN MODE STREAMING (M2)
        -- =====================================================================
        streaming_mode <= '1';
        wait until rising_edge(clk);

        -- 8. Tulis 1024 byte frame 2 di mode streaming
        for i in 0 to 1023 loop
            wait until rising_edge(clk);
            s_axis_valid <= '1';
            s_axis_data  <= std_logic_vector(to_unsigned((i + 20) mod 256, 8));
        end loop;
        wait until rising_edge(clk);
        s_axis_valid <= '0';

        -- 9. Uji Delayed Swap: sink masih membaca (read_busy = 1), packet_valid tiba
        read_busy <= '1';
        wait until rising_edge(clk);
        stream_valid <= '1';
        wait until rising_edge(clk);
        stream_valid <= '0';
        wait until rising_edge(clk);

        -- Periksa bahwa bank depan belum bertukar saat sink membaca
        rd_addr <= to_unsigned(0, 10);
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        assert rd_data = std_logic_vector(to_unsigned(10 mod 256, 8))
            report "Tearing terdeteksi: bank depan bertukar sebelum sink selesai membaca!" severity failure;
        report "Uji 4 Sukses: Delayed swap menahan pertukaran bank saat read_busy = 1." severity note;

        -- 10. Selesai membaca (read_busy = 0), verifikasi delayed swap dieksekusi seketika
        read_busy <= '0';
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        rd_addr <= to_unsigned(0, 10);
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        assert rd_data = std_logic_vector(to_unsigned(20 mod 256, 8))
            report "Delayed swap gagal mengeksekusi pertukaran bank setelah sink idle!" severity failure;
        report "Uji 5 Sukses: Delayed swap berhasil mengeksekusi pertukaran setelah sink idle." severity note;

        -- 11. Uji Stream Drop: tulis 512 byte rusak lalu beri pulsa stream_drop
        for i in 0 to 511 loop
            wait until rising_edge(clk);
            s_axis_valid <= '1';
            s_axis_data  <= x"EE";
        end loop;
        wait until rising_edge(clk);
        s_axis_valid <= '0';
        stream_drop <= '1';
        wait until rising_edge(clk);
        stream_drop <= '0';
        wait until rising_edge(clk);

        -- Verifikasi bank depan tetap menampilkan frame 2 yang valid
        rd_addr <= to_unsigned(0, 10);
        wait until rising_edge(clk);
        wait until rising_edge(clk);
        assert rd_data = std_logic_vector(to_unsigned(20 mod 256, 8))
            report "Frame drop mengganggu bank depan!" severity failure;
        report "Uji 6 Sukses: Frame rusak dibuang tanpa merusak tampilan frame sebelumnya." severity note;

        -- 12. Uji Streaming Overrun: frame valid tiba saat swap masih tertunda
        for i in 0 to 1023 loop
            wait until rising_edge(clk);
            s_axis_valid <= '1';
            s_axis_data  <= std_logic_vector(to_unsigned((i + 30) mod 256, 8));
        end loop;
        wait until rising_edge(clk);
        s_axis_valid <= '0';

        read_busy <= '1';
        wait until rising_edge(clk);
        stream_valid <= '1'; -- Masuk status pending_swap
        wait until rising_edge(clk);
        stream_valid <= '0';
        wait until rising_edge(clk);

        -- Paket berikutnya tiba saat masih pending_swap
        stream_valid <= '1';
        wait until rising_edge(clk);
        stream_valid <= '0';
        wait until rising_edge(clk);
        assert stream_overrun = '1'
            report "Streaming overrun gagal terdeteksi saat paket baru tiba pada pending swap!" severity failure;
        report "Uji 7 Sukses: Streaming overrun terdeteksi saat paket tiba pada pending swap." severity note;

        read_busy <= '0';
        wait until rising_edge(clk);

        report "TEST PASSED: frame_buffer lolos seluruh uji M1 dan M2 (delayed swap, drop, streaming overrun).";
        wait for 50 ns;
        std.env.stop;
    end process;
end architecture sim;
