-- sim/tb_ascii_sink.vhd
-- Testbench komprehensif untuk ascii_sink:
-- 1. Uji pola non-uniform (baris piksel bervariasi: AA, 55, FF, 00) untuk mendeteksi bug delay atau salah baris.
-- 2. Uji byte-exact seluruh 90 frame golden (95.310 byte) terhadap data/golden/ascii.hex.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity tb_ascii_sink is
end entity tb_ascii_sink;

architecture sim of tb_ascii_sink is
    constant CLK_PERIOD : time := 10 ns;

    signal clk      : std_logic := '0';
    signal rst      : std_logic := '1';
    signal start    : std_logic := '0';
    signal busy     : std_logic;
    signal fb_addr  : unsigned(9 downto 0);
    signal fb_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_data  : std_logic_vector(7 downto 0);
    signal tx_valid : std_logic;
    signal tx_ready : std_logic := '1';

    -- Mock frame memory (1024 byte)
    type ram_t is array (0 to 1023) of std_logic_vector(7 downto 0);
    signal mock_fb : ram_t := (others => (others => '0'));
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

    uut : entity work.ascii_sink
        generic map (
            RAMP_SELECT => "RAMP_A"
        )
        port map (
            clk      => clk,
            rst      => rst,
            start    => start,
            busy     => busy,
            fb_addr  => fb_addr,
            fb_data  => fb_data,
            tx_data  => tx_data,
            tx_valid => tx_valid,
            tx_ready => tx_ready
        );

    -- Mock synchronous memory read (1 siklus latensi BRAM)
    process(clk)
    begin
        if rising_edge(clk) then
            fb_data <= mock_fb(to_integer(fb_addr));
        end if;
    end process;

    stim_proc : process
        file f_frames : text;
        file f_ascii  : text;
        variable l_in : line;
        variable byte_val : std_logic_vector(7 downto 0);
        variable exp_val  : std_logic_vector(7 downto 0);

        variable matched_bytes  : integer := 0;
        variable mismatch_bytes : integer := 0;
        variable frame_bytes    : integer := 0;
        variable row_idx        : integer := 0;
        variable col_idx        : integer := 0;
    begin
        rst <= '1';
        wait for 50 ns;
        wait until rising_edge(clk);
        rst <= '0';
        wait for 30 ns;

        -----------------------------------------------------------------------
        -- KASUS 1: Pola Non-Uniform (Baris Piksel Berbeda)
        -- Baris 4k+0 = 0xAA (10101010 -> 1 piksel putih per 2 bit)
        -- Baris 4k+1 = 0x55 (01010101 -> 1 piksel putih per 2 bit)
        -- Baris 4k+2 = 0xFF (11111111 -> 2 piksel putih per 2 bit)
        -- Baris 4k+3 = 0x00 (00000000 -> 0 piksel putih per 2 bit)
        -- Total piksel putih per blok 2x4 = 1 + 1 + 2 + 0 = 4 (Karakter Ramp A = '=')
        -- Setiap pergeseran baris / delay siklus akan mengubah densitas != 4!
        -----------------------------------------------------------------------
        report "=== MEMULAI UJI 1: Pola Non-Uniform ===" severity note;
        for y in 0 to 63 loop
            for x_byte in 0 to 15 loop
                case (y mod 4) is
                    when 0 => mock_fb(y * 16 + x_byte) <= x"AA";
                    when 1 => mock_fb(y * 16 + x_byte) <= x"55";
                    when 2 => mock_fb(y * 16 + x_byte) <= x"FF";
                    when others => mock_fb(y * 16 + x_byte) <= x"00";
                end case;
            end loop;
        end loop;

        wait until rising_edge(clk);
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        frame_bytes := 0;
        row_idx := 0;
        col_idx := 0;
        while true loop
            wait until rising_edge(clk);
            if tx_valid = '1' and tx_ready = '1' then
                frame_bytes := frame_bytes + 1;

                -- Verifikasi Header ANSI \x1b[H
                if frame_bytes = 1 then
                    assert tx_data = x"1B" report "Non-uniform: Byte 1 bukan ESC!" severity failure;
                elsif frame_bytes = 2 then
                    assert tx_data = x"5B" report "Non-uniform: Byte 2 bukan '['!" severity failure;
                elsif frame_bytes = 3 then
                    assert tx_data = x"48" report "Non-uniform: Byte 3 bukan 'H'!" severity failure;
                else
                    -- Karakter baris
                    if col_idx < 64 then
                        assert tx_data = x"3D" -- '='
                            report "Non-uniform Mismatch di baris " & integer'image(row_idx) &
                                   " kolom " & integer'image(col_idx) &
                                   ": diharapkan '=' (0x3D), didapat: " &
                                   integer'image(to_integer(unsigned(tx_data)))
                            severity failure;
                        col_idx := col_idx + 1;
                    elsif col_idx = 64 then
                        assert tx_data = x"0D" report "Non-uniform: Diharapkan CR (0x0D)" severity failure;
                        col_idx := col_idx + 1;
                    elsif col_idx = 65 then
                        assert tx_data = x"0A" report "Non-uniform: Diharapkan LF (0x0A)" severity failure;
                        col_idx := 0;
                        row_idx := row_idx + 1;
                    end if;
                end if;

                if frame_bytes = 1059 then
                    exit;
                end if;
            end if;
        end loop;

        wait until rising_edge(clk);
        wait for 1 ps;
        assert busy = '0' report "Non-uniform: busy masih 1!" severity failure;
        report "UJI 1 SUKSES: Pola non-uniform terverifikasi sempurna (densitas 4 = '=' di seluruh 16 baris)." severity note;

        -----------------------------------------------------------------------
        -- KASUS 2: Verifikasi Byte-Exact 90 Frame Golden Bad Apple
        -- Membaca 90 frame masukan dari data/golden/clip_bram.hex
        -- Membandingkan 95.310 byte keluaran terhadap data/golden/ascii.hex
        -----------------------------------------------------------------------
        report "=== MEMULAI UJI 2: Verifikasi 90 Frame Golden (95.310 Byte) ===" severity note;

        file_open(f_frames, "data/golden/clip_bram.hex", read_mode);
        file_open(f_ascii, "data/golden/ascii.hex", read_mode);

        matched_bytes  := 0;
        mismatch_bytes := 0;

        for f in 0 to 89 loop
            -- 1. Muat 1.024 byte frame f ke mock_fb
            for i in 0 to 1023 loop
                readline(f_frames, l_in);
                hread(l_in, byte_val);
                mock_fb(i) <= byte_val;
            end loop;

            -- 2. Picu start untuk frame f
            wait until rising_edge(clk);
            start <= '1';
            wait until rising_edge(clk);
            start <= '0';

            -- 3. Tangkap 1.059 byte keluaran dan bandingkan byte-exact
            frame_bytes := 0;
            while frame_bytes < 1059 loop
                wait until rising_edge(clk);
                if tx_valid = '1' and tx_ready = '1' then
                    frame_bytes := frame_bytes + 1;

                    -- Baca byte referensi dari ascii.hex
                    readline(f_ascii, l_in);
                    hread(l_in, exp_val);

                    if tx_data = exp_val then
                        matched_bytes := matched_bytes + 1;
                    else
                        mismatch_bytes := mismatch_bytes + 1;
                        report "MISMATCH Frame " & integer'image(f) &
                               " Byte #" & integer'image(frame_bytes) &
                               ": Exp=" & integer'image(to_integer(unsigned(exp_val))) &
                               " Got=" & integer'image(to_integer(unsigned(tx_data)))
                               severity error;
                    end if;
                end if;
            end loop;

            wait until rising_edge(clk);
            wait for 1 ps;
            assert busy = '0' report "Frame " & integer'image(f) & ": busy tidak turun!" severity failure;
        end loop;

        file_close(f_frames);
        file_close(f_ascii);

        report "HASIL UJI 2 ASCII_SINK:" severity note;
        report "  Total byte dibandingkan : " & integer'image(matched_bytes + mismatch_bytes) severity note;
        report "  Jumlah byte cocok       : " & integer'image(matched_bytes) severity note;
        report "  Jumlah ketidakcocokan   : " & integer'image(mismatch_bytes) severity note;

        assert mismatch_bytes = 0
            report "Gagal! Terdapat " & integer'image(mismatch_bytes) & " ketidakcocokan!"
            severity failure;

        assert matched_bytes = 95310
            report "Gagal! Total byte cocok (" & integer'image(matched_bytes) & ") != 95310!"
            severity failure;

        report "TEST PASSED: ascii_sink lulus uji non-uniform dan byte-exact terhadap 90 frame golden (95.310 byte cocok, 0 mismatch)." severity note;
        wait for 100 ns;
        std.env.stop;
    end process;
end architecture sim;
