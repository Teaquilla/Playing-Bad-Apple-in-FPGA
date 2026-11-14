-- sim/tb_frame_buffer_dual.vhd
-- Testbench mandiri untuk memverifikasi duplikasi penyimpanan BRAM mem2
-- dan pembacaan paralel port B2 (rd2_addr / rd2_data) untuk subsistem OLED.
-- Memverifikasi konsistensi rd2_data = rd_data pada pola acak di kedua bank,
-- melewati >= 3 swap termasuk delayed swap.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_frame_buffer_dual is
end entity tb_frame_buffer_dual;

architecture sim of tb_frame_buffer_dual is
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
    signal swap_done      : std_logic;
    signal s_axis_data    : std_logic_vector(7 downto 0) := (others => '0');
    signal s_axis_valid   : std_logic := '0';
    signal s_axis_ready   : std_logic;
    signal s_axis_last    : std_logic := '0';

    -- Port 1 (ASCII sink / Display)
    signal rd_addr        : unsigned(9 downto 0) := (others => '0');
    signal rd_data        : std_logic_vector(7 downto 0);

    -- Port 2 (OLED SPI Controller)
    signal rd2_addr       : unsigned(9 downto 0) := (others => '0');
    signal rd2_data       : std_logic_vector(7 downto 0);

    -- Pola referensi untuk 4 frame
    type byte_array_t is array (0 to 1023) of std_logic_vector(7 downto 0);

    function gen_pattern(seed_mult : integer; seed_add : integer) return byte_array_t is
        variable res : byte_array_t;
    begin
        for i in 0 to 1023 loop
            res(i) := std_logic_vector(to_unsigned((i * seed_mult + seed_add) mod 256, 8));
        end loop;
        return res;
    end function;

    constant PATTERN_F0 : byte_array_t := gen_pattern(73, 17);
    constant PATTERN_F1 : byte_array_t := gen_pattern(109, 89);
    constant PATTERN_F2 : byte_array_t := gen_pattern(197, 233);
    constant PATTERN_F3 : byte_array_t := gen_pattern(13, 97);

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
            swap_done      => swap_done,
            s_axis_data    => s_axis_data,
            s_axis_valid   => s_axis_valid,
            s_axis_ready   => s_axis_ready,
            s_axis_last    => s_axis_last,
            rd_addr        => rd_addr,
            rd_data        => rd_data,
            rd2_addr       => rd2_addr,
            rd2_data       => rd2_data
        );

    stim_proc : process
        variable rand_addr : integer;
        variable rand_addr2: integer;
    begin
        rst <= '1';
        wait for 50 ns;
        wait until rising_edge(clk);
        rst <= '0';
        wait for 20 ns;

        ------------------------------------------------------------------------
        -- UJI 1: MODE M1 - Tulis Frame 0 (Bank Belakang) lalu Lakukan SWAP 1
        ------------------------------------------------------------------------
        report "Uji 1: Menulis Frame 0 ke bank belakang...";
        for i in 0 to 1023 loop
            wait until rising_edge(clk);
            s_axis_valid <= '1';
            s_axis_data  <= PATTERN_F0(i);
            if i = 1023 then
                s_axis_last <= '1';
            else
                s_axis_last <= '0';
            end if;
        end loop;
        wait until rising_edge(clk);
        s_axis_valid <= '0';
        s_axis_last  <= '0';
        wait until rising_edge(clk);

        -- Eksekusi SWAP 1
        swap_req <= '1';
        wait until rising_edge(clk);
        swap_req <= '0';
        wait until rising_edge(clk);

        -- Verifikasi pembacaan dual-port pada Frame 0 di bank depan
        report "Uji 1: Verifikasi kesesuaian rd2_data = rd_data pada 100 alamat acak Frame 0...";
        for k in 0 to 99 loop
            rand_addr := (k * 317 + 53) mod 1024;
            rd_addr   <= to_unsigned(rand_addr, 10);
            rd2_addr  <= to_unsigned(rand_addr, 10);
            wait until rising_edge(clk); -- Clock cycle untuk synchronous BRAM read
            wait for 1 ns;

            assert rd_data = PATTERN_F0(rand_addr)
                report "Uji 1 GAGAL: rd_data tidak cocok pada alamat " & integer'image(rand_addr)
                severity failure;
            assert rd2_data = PATTERN_F0(rand_addr)
                report "Uji 1 GAGAL: rd2_data (mem2) tidak cocok pada alamat " & integer'image(rand_addr)
                severity failure;
            assert rd2_data = rd_data
                report "Uji 1 GAGAL: rd2_data /= rd_data pada alamat " & integer'image(rand_addr)
                severity failure;
        end loop;
        report "Uji 1 SUKSES: SWAP 1 dan pembacaan paralel Frame 0 terverifikasi bit-exact.";

        ------------------------------------------------------------------------
        -- UJI 2: MODE M1 - Tulis Frame 1 ke Bank Sebaliknya lalu SWAP 2
        ------------------------------------------------------------------------
        report "Uji 2: Menulis Frame 1 ke bank belakang sebaliknya...";
        for i in 0 to 1023 loop
            wait until rising_edge(clk);
            s_axis_valid <= '1';
            s_axis_data  <= PATTERN_F1(i);
            if i = 1023 then
                s_axis_last <= '1';
            else
                s_axis_last <= '0';
            end if;
        end loop;
        wait until rising_edge(clk);
        s_axis_valid <= '0';
        s_axis_last  <= '0';
        wait until rising_edge(clk);

        -- Eksekusi SWAP 2
        swap_req <= '1';
        wait until rising_edge(clk);
        swap_req <= '0';
        wait until rising_edge(clk);

        -- Verifikasi pembacaan dual-port pada Frame 1
        report "Uji 2: Verifikasi kesesuaian rd2_data = rd_data pada 100 alamat acak Frame 1...";
        for k in 0 to 99 loop
            rand_addr := (k * 491 + 79) mod 1024;
            rd_addr   <= to_unsigned(rand_addr, 10);
            rd2_addr  <= to_unsigned(rand_addr, 10);
            wait until rising_edge(clk);
            wait for 1 ns;

            assert rd_data = PATTERN_F1(rand_addr)
                report "Uji 2 GAGAL: rd_data tidak cocok pada alamat " & integer'image(rand_addr)
                severity failure;
            assert rd2_data = PATTERN_F1(rand_addr)
                report "Uji 2 GAGAL: rd2_data (mem2) tidak cocok pada alamat " & integer'image(rand_addr)
                severity failure;
            assert rd2_data = rd_data
                report "Uji 2 GAGAL: rd2_data /= rd_data pada alamat " & integer'image(rand_addr)
                severity failure;
        end loop;
        report "Uji 2 SUKSES: SWAP 2 dan pembacaan paralel Frame 1 terverifikasi bit-exact.";

        ------------------------------------------------------------------------
        -- UJI 3: MODE M2 (STREAMING) - Tulis Frame 2 lalu SWAP 3 (Tanpa Delay)
        ------------------------------------------------------------------------
        report "Uji 3: Mode streaming M2, menulis Frame 2...";
        streaming_mode <= '1';
        wait until rising_edge(clk);

        for i in 0 to 1023 loop
            wait until rising_edge(clk);
            s_axis_valid <= '1';
            s_axis_data  <= PATTERN_F2(i);
        end loop;
        wait until rising_edge(clk);
        s_axis_valid <= '0';

        -- SWAP 3 via stream_valid saat read_busy = 0
        read_busy    <= '0';
        stream_valid <= '1';
        wait until rising_edge(clk);
        stream_valid <= '0';
        wait until rising_edge(clk);
        assert swap_done = '1' report "Uji 3 GAGAL: swap_done tidak aktif pada SWAP 3!" severity failure;

        -- Verifikasi Frame 2 pada bank depan
        report "Uji 3: Verifikasi Frame 2 pada dual-port...";
        for k in 0 to 99 loop
            rand_addr := (k * 137 + 11) mod 1024;
            rd_addr   <= to_unsigned(rand_addr, 10);
            rd2_addr  <= to_unsigned(rand_addr, 10);
            wait until rising_edge(clk);
            wait for 1 ns;

            assert rd_data = PATTERN_F2(rand_addr)
                report "Uji 3 GAGAL: rd_data tidak cocok pada Frame 2" severity failure;
            assert rd2_data = PATTERN_F2(rand_addr)
                report "Uji 3 GAGAL: rd2_data tidak cocok pada Frame 2" severity failure;
            assert rd2_data = rd_data
                report "Uji 3 GAGAL: rd2_data /= rd_data pada Frame 2" severity failure;
        end loop;
        report "Uji 3 SUKSES: SWAP 3 streaming terverifikasi.";

        ------------------------------------------------------------------------
        -- UJI 4: MODE M2 (STREAMING) - Delayed Swap (SWAP 4) saat read_busy = 1
        ------------------------------------------------------------------------
        report "Uji 4: Menulis Frame 3 dengan kondisi read_busy = 1 (Delayed Swap)...";
        read_busy <= '1';
        wait until rising_edge(clk);

        for i in 0 to 1023 loop
            wait until rising_edge(clk);
            s_axis_valid <= '1';
            s_axis_data  <= PATTERN_F3(i);
        end loop;
        wait until rising_edge(clk);
        s_axis_valid <= '0';

        -- stream_valid tiba saat read_busy = 1 -> swap harus ditahan (pending_swap)
        stream_valid <= '1';
        wait until rising_edge(clk);
        stream_valid <= '0';
        wait until rising_edge(clk);

        assert swap_done = '0' report "Uji 4 GAGAL: swap dieksekusi prematur saat read_busy = 1!" severity failure;

        -- Verifikasi bahwa bank depan MASIH menampilkan Frame 2 (tidak tearing!)
        rd_addr  <= to_unsigned(42, 10);
        rd2_addr <= to_unsigned(42, 10);
        wait until rising_edge(clk);
        wait for 1 ns;
        assert rd_data = PATTERN_F2(42) report "Uji 4 GAGAL: bank depan rusak saat swap ditahan!" severity failure;
        assert rd2_data = PATTERN_F2(42) report "Uji 4 GAGAL: mem2 rusak saat swap ditahan!" severity failure;

        -- Sink selesai membaca: lepaskan read_busy -> swap harus dieksekusi sekarang!
        report "Uji 4: Melepaskan read_busy <= '0' untuk memicu delayed swap...";
        read_busy <= '0';
        wait until rising_edge(clk);
        wait for 1 ns;
        assert swap_done = '1' report "Uji 4 GAGAL: delayed swap tidak dieksekusi setelah sink idle!" severity failure;

        -- Verifikasi Frame 3 kini aktif di bank depan pada kedua port
        report "Uji 4: Verifikasi Frame 3 setelah delayed swap pada 100 alamat acak...";
        for k in 0 to 99 loop
            rand_addr  := (k * 229 + 17) mod 1024;
            rand_addr2 := (k * 181 + 43) mod 1024;
            rd_addr    <= to_unsigned(rand_addr, 10);
            rd2_addr   <= to_unsigned(rand_addr2, 10);
            wait until rising_edge(clk);
            wait for 1 ns;

            assert rd_data = PATTERN_F3(rand_addr)
                report "Uji 4 GAGAL: rd_data tidak cocok pada alamat " & integer'image(rand_addr)
                severity failure;
            assert rd2_data = PATTERN_F3(rand_addr2)
                report "Uji 4 GAGAL: rd2_data tidak cocok pada alamat " & integer'image(rand_addr2)
                severity failure;
        end loop;

        -- Uji penuh 1024 alamat identik pada Frame 3
        report "Uji 5: Verifikasi bit-exact seluruh 1024 byte pada port rd dan rd2...";
        for i in 0 to 1023 loop
            rd_addr  <= to_unsigned(i, 10);
            rd2_addr <= to_unsigned(i, 10);
            wait until rising_edge(clk);
            wait for 1 ns;

            assert rd_data = PATTERN_F3(i)
                report "Uji 5 GAGAL: rd_data mismatch pada indeks " & integer'image(i) severity failure;
            assert rd2_data = PATTERN_F3(i)
                report "Uji 5 GAGAL: rd2_data mismatch pada indeks " & integer'image(i) severity failure;
            assert rd2_data = rd_data
                report "Uji 5 GAGAL: rd2_data /= rd_data pada indeks " & integer'image(i) severity failure;
        end loop;

        report "TEST PASSED: tb_frame_buffer_dual lolos seluruh pengujian (duplikasi mem2, dual-port read, 4 swap termasuk delayed swap).";
        finish;
    end process;
end architecture sim;
