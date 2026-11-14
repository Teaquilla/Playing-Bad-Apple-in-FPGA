--------------------------------------------------------------------------------
-- sim/tb_parser_audio.vhd
-- Testbench mandiri untuk packet_parser dengan ekstensi audio (Milestone M4)
-- Mengikuti pola tb_stream_rx:
--   UART stream -> rx_fifo -> packet_parser -> audio_fifo (port tulis)
--                                           -> rle_decoder -> monitor frames.hex
-- Vektor uji berasal dari python/make_mixed_stream.py (Milestone M4)
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

entity tb_parser_audio is
end entity tb_parser_audio;

architecture sim of tb_parser_audio is

    -- Parameter clock & timing (100 MHz, dipercepat 25 MBaud seperti tb_stream_rx)
    constant CLK_PERIOD : time := 10 ns;
    constant BAUD_RATE  : integer := 25_000_000;
    constant BIT_TIME   : time := 40 ns;

    -- Sinyal Clock & Reset Global
    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal rx  : std_logic := '1';

    -- Jalur UART RX -> RX FIFO
    signal uart_data  : std_logic_vector(7 downto 0);
    signal uart_valid : std_logic;

    -- Jalur RX FIFO -> Packet Parser (Spekulatif)
    signal fifo_full       : std_logic;
    signal fifo_rd_req     : std_logic;
    signal fifo_rd_data    : std_logic_vector(7 downto 0);
    signal fifo_spec_empty : std_logic;
    signal fifo_mark_sof   : std_logic;
    signal fifo_commit     : std_logic;
    signal fifo_rollback   : std_logic;

    -- Jalur Packet Parser Video -> RLE Decoder
    signal parse_data       : std_logic_vector(7 downto 0);
    signal parse_valid      : std_logic;
    signal parse_ready      : std_logic;
    signal parse_last       : std_logic;
    signal packet_valid     : std_logic;
    signal packet_error     : std_logic;
    signal frame_id_out     : std_logic_vector(15 downto 0);
    signal cnt_valid_frames : unsigned(15 downto 0);
    signal cnt_chk_errors   : unsigned(15 downto 0);
    signal cnt_len_errors   : unsigned(15 downto 0);
    signal cnt_resyncs      : unsigned(15 downto 0);

    -- Jalur Packet Parser Audio -> Audio FIFO
    signal aud_start         : std_logic;
    signal aud_len           : unsigned(10 downto 0);
    signal aud_valid         : std_logic;
    signal aud_data          : std_logic_vector(7 downto 0);
    signal aud_commit        : std_logic;
    signal aud_rollback      : std_logic;
    signal cnt_audio_packets : unsigned(15 downto 0);
    signal aud_reject        : std_logic := '0';
    signal force_reject      : std_logic := '0';
    signal enable_force_reject : std_logic := '0';
    signal check_ramp        : boolean := true;
    signal cnt_aud_rollbacks : integer := 0;

    -- Sinyal Audio FIFO
    signal afifo_wr_reject     : std_logic;
    signal afifo_rd_req        : std_logic := '0';
    signal afifo_rd_data       : std_logic_vector(7 downto 0);
    signal afifo_level         : std_logic_vector(11 downto 0);
    signal afifo_playing       : std_logic;
    signal afifo_cnt_overflow  : std_logic_vector(15 downto 0);
    signal afifo_cnt_underflow : std_logic_vector(15 downto 0);
    signal afifo_cnt_drop      : std_logic_vector(15 downto 0);
    signal afifo_cnt_repeat    : std_logic_vector(15 downto 0);

    -- Jalur RLE Decoder -> Monitor
    signal dec_data       : std_logic_vector(7 downto 0);
    signal dec_valid      : std_logic;
    signal dec_ready      : std_logic := '1';
    signal dec_last       : std_logic;
    signal dec_frame_done : std_logic;
    signal dec_err_run    : std_logic;
    signal dec_err_len    : std_logic;

    -- Papan Skor & Penghitung Pengujian
    signal video_bytes_verified : integer := 0;
    signal video_mismatches     : integer := 0;
    signal audio_bytes_verified : integer := 0;
    signal audio_mismatches     : integer := 0;
    signal test_done            : boolean := false;
    signal drain_audio          : boolean := false;

    -- Prosedur pengirim serial UART (mengikuti tb_stream_rx)
    procedure send_uart_byte(
        signal tx_line : out std_logic;
        data           : in  std_logic_vector(7 downto 0)
    ) is
    begin
        tx_line <= '0';
        wait for BIT_TIME;
        for i in 0 to 7 loop
            tx_line <= data(i);
            wait for BIT_TIME;
        end loop;
        tx_line <= '1';
        wait for BIT_TIME;
    end procedure;

    procedure send_hex_file(
        signal tx_line : out std_logic;
        file_path      : in  string
    ) is
        file f : text open read_mode is file_path;
        variable l : line;
        variable val : std_logic_vector(7 downto 0);
    begin
        while not endfile(f) loop
            readline(f, l);
            hread(l, val);
            send_uart_byte(tx_line, val);
        end loop;
    end procedure;

begin

    -- Pembangkit clock 100 MHz
    clk <= not clk after CLK_PERIOD / 2;

    -- Gabungan sinyal reject audio (force_reject kombinasional saat aud_start)
    force_reject <= '1' when (enable_force_reject = '1' and frame_id_out = x"800C" and aud_start = '1') else '0';
    aud_reject   <= afifo_wr_reject or force_reject;

    rollback_cnt_proc : process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                cnt_aud_rollbacks <= 0;
            elsif aud_rollback = '1' then
                cnt_aud_rollbacks <= cnt_aud_rollbacks + 1;
            end if;
        end if;
    end process;

    -- -------------------------------------------------------------------------
    -- 1. Instansiasi UART RX
    -- -------------------------------------------------------------------------
    u_uart_rx : entity work.uart_rx
        generic map (
            CLK_FREQ_HZ => 100_000_000,
            BAUD_RATE   => BAUD_RATE
        )
        port map (
            clk     => clk,
            rst     => rst,
            rx      => rx,
            m_data  => uart_data,
            m_valid => uart_valid
        );

    -- -------------------------------------------------------------------------
    -- 2. Instansiasi RX FIFO
    -- -------------------------------------------------------------------------
    u_rx_fifo : entity work.rx_fifo
        generic map (
            FIFO_DEPTH => 2048
        )
        port map (
            clk          => clk,
            rst          => rst,
            wr_en        => uart_valid,
            wr_data      => uart_data,
            full         => fifo_full,
            rd_req       => fifo_rd_req,
            rd_data      => fifo_rd_data,
            spec_empty   => fifo_spec_empty,
            mark_sof     => fifo_mark_sof,
            commit       => fifo_commit,
            rollback     => fifo_rollback,
            commit_empty => open,
            overflow_err => open
        );

    -- -------------------------------------------------------------------------
    -- 3. Instansiasi Packet Parser (DUT)
    -- -------------------------------------------------------------------------
    u_parser : entity work.packet_parser
        generic map (
            PAYLOAD_LEN_MIN => 64,
            PAYLOAD_LEN_MAX => 1024,
            TIMEOUT_CYCLES  => 500
        )
        port map (
            clk               => clk,
            rst               => rst,
            fifo_rd_req       => fifo_rd_req,
            fifo_rd_data      => fifo_rd_data,
            fifo_spec_empty   => fifo_spec_empty,
            fifo_mark_sof     => fifo_mark_sof,
            fifo_commit       => fifo_commit,
            fifo_rollback     => fifo_rollback,
            m_axis_data       => parse_data,
            m_axis_valid      => parse_valid,
            m_axis_ready      => parse_ready,
            m_axis_last       => parse_last,
            packet_valid      => packet_valid,
            packet_error      => packet_error,
            frame_id_out      => frame_id_out,
            cnt_valid_frames  => cnt_valid_frames,
            cnt_chk_errors    => cnt_chk_errors,
            cnt_len_errors    => cnt_len_errors,
            cnt_resyncs       => cnt_resyncs,
            aud_start         => aud_start,
            aud_len           => aud_len,
            aud_valid         => aud_valid,
            aud_data          => aud_data,
            aud_commit        => aud_commit,
            aud_rollback      => aud_rollback,
            cnt_audio_packets => cnt_audio_packets,
            aud_reject        => aud_reject
        );

    -- -------------------------------------------------------------------------
    -- 4. Instansiasi Audio FIFO
    -- -------------------------------------------------------------------------
    u_audio_fifo : entity work.audio_fifo
        generic map (
            DWELL_CYCLES    => 300_000_000,
            SLIP_MIN_CYCLES => 5_000_000
        )
        port map (
            clk           => clk,
            rst           => rst,
            wr_start      => aud_start,
            wr_len        => std_logic_vector(aud_len),
            wr_valid      => aud_valid,
            wr_data       => aud_data,
            wr_commit     => aud_commit,
            wr_rollback   => aud_rollback,
            wr_reject     => afifo_wr_reject,
            rd_req        => afifo_rd_req,
            rd_data       => afifo_rd_data,
            level         => afifo_level,
            playing       => afifo_playing,
            cnt_overflow  => afifo_cnt_overflow,
            cnt_underflow => afifo_cnt_underflow,
            cnt_drop      => afifo_cnt_drop,
            cnt_repeat    => afifo_cnt_repeat
        );

    -- -------------------------------------------------------------------------
    -- 5. Instansiasi RLE Decoder (pola tb_stream_rx)
    -- -------------------------------------------------------------------------
    u_decoder : entity work.rle_decoder
        generic map (
            FRAME_WIDTH  => 128,
            FRAME_HEIGHT => 64,
            TOTAL_BYTES  => 1024
        )
        port map (
            clk          => clk,
            rst          => rst,
            s_axis_data  => parse_data,
            s_axis_valid => parse_valid,
            s_axis_ready => parse_ready,
            s_axis_last  => parse_last,
            m_axis_data  => dec_data,
            m_axis_valid => dec_valid,
            m_axis_ready => dec_ready,
            m_axis_last  => dec_last,
            frame_done   => dec_frame_done,
            err_run      => dec_err_run,
            err_len      => dec_err_len
        );

    -- -------------------------------------------------------------------------
    -- 6. Assertion Protokol Audio Parser
    -- -------------------------------------------------------------------------
    protocol_check_proc : process(clk)
        variable v_cycles_since_start : integer := 999;
        variable v_cycles_since_valid : integer := 999;
        variable v_has_started        : boolean := false;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v_cycles_since_start := 999;
                v_cycles_since_valid := 999;
                v_has_started        := false;
            else
                -- 1. Evaluasi aud_start
                if aud_start = '1' then
                    v_cycles_since_start := 0;
                    v_has_started        := true;
                elsif v_has_started then
                    v_cycles_since_start := v_cycles_since_start + 1;
                end if;

                -- 2. Evaluasi aud_valid
                if aud_valid = '1' then
                    -- Assertion A: Tidak ada aud_valid tanpa aud_start
                    assert v_has_started
                        report "Asersi Protokol GAGAL: aud_valid muncul tanpa aud_start!"
                        severity failure;

                    -- Assertion B: aud_start mendahului aud_valid pertama minimal 1 siklus
                    assert v_cycles_since_start >= 1
                        report "Asersi Protokol GAGAL: aud_valid muncul bersamaan dengan aud_start!"
                        severity failure;

                    v_cycles_since_valid := 0;
                else
                    if v_cycles_since_valid < 999 then
                        v_cycles_since_valid := v_cycles_since_valid + 1;
                    end if;
                end if;

                -- 3. Evaluasi aud_commit dan aud_rollback
                if aud_commit = '1' or aud_rollback = '1' then
                    -- Assertion C: aud_commit/rollback minimal 1 siklus setelah aud_valid terakhir
                    assert v_cycles_since_valid >= 1
                        report "Asersi Protokol GAGAL: aud_commit/rollback muncul pada siklus yang sama dengan aud_valid terakhir!"
                        severity failure;

                    v_has_started := false;
                end if;
            end if;
        end if;
    end process;

    -- -------------------------------------------------------------------------
    -- 7. Monitor & Papan Skor Sisi Baca Audio FIFO
    -- -------------------------------------------------------------------------
    audio_scoreboard_proc : process
        variable v_expected_sample : integer := 0;
        variable v_actual_sample   : integer := 0;
    begin
        wait until rst = '0';
        -- Tunggu hingga pre-roll selesai (afifo_playing='1') dan register BRAM stabil
        wait until afifo_playing = '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        loop
            wait until rising_edge(clk);
            exit when test_done;

            if rst = '0' then
                -- Drains FIFO saat playing aktif dan level > 1000, atau saat drain_audio dipicu
                if (unsigned(afifo_level) > 1000 or drain_audio) and unsigned(afifo_level) > 0 then
                    v_actual_sample   := to_integer(unsigned(afifo_rd_data));
                    v_expected_sample := audio_bytes_verified mod 256;

                    if check_ramp then
                        if v_actual_sample /= v_expected_sample then
                            audio_mismatches <= audio_mismatches + 1;
                            report "MISMATCH Papan Skor Audio pada byte ke-" & integer'image(audio_bytes_verified) &
                                   ": didapat 0x" & to_hstring(afifo_rd_data) &
                                   ", diharapkan 0x" & integer'image(v_expected_sample)
                                   severity error;
                        end if;
                        audio_bytes_verified <= audio_bytes_verified + 1;
                    end if;

                    -- Majukan pointer baca audio_fifo (pulsa 1 siklus)
                    afifo_rd_req <= '1';
                    wait until rising_edge(clk);
                    afifo_rd_req <= '0';
                    wait until rising_edge(clk);
                end if;
            end if;
        end loop;
        wait;
    end process;

    -- -------------------------------------------------------------------------
    -- 8. Monitor Keluaran Video Kanonik terhadap data/golden/frames.hex (92.160 B)
    -- -------------------------------------------------------------------------
    video_monitor_proc : process
        file f_gold : text open read_mode is "data/golden/frames.hex";
        variable l_gold : line;
        variable expected_byte : std_logic_vector(7 downto 0);
    begin
        wait until rst = '0';
        while not endfile(f_gold) loop
            wait until rising_edge(clk) and dec_valid = '1' and dec_ready = '1';
            readline(f_gold, l_gold);
            hread(l_gold, expected_byte);
            if dec_data /= expected_byte then
                video_mismatches <= video_mismatches + 1;
                report "MISMATCH Video pada byte " & integer'image(video_bytes_verified) &
                       ": didapat 0x" & to_hstring(dec_data) &
                       ", diharapkan 0x" & to_hstring(expected_byte) severity error;
            end if;
            video_bytes_verified <= video_bytes_verified + 1;
        end loop;
        wait;
    end process;

    -- -------------------------------------------------------------------------
    -- 9. Stimulus Pengujian Utama
    -- -------------------------------------------------------------------------
    stim_proc : process
    begin
        -- Inisialisasi & Reset
        rst <= '1';
        rx  <= '1';
        wait for 100 ns;
        rst <= '0';
        wait for 200 ns;

        -- =====================================================================
        -- UJI 1: Vektor Campuran Bersih (mixed_stream_clean.hex)
        -- =====================================================================
        report "=== [UJI 1] Mengirim data/golden/mixed_stream_clean.hex (90 Video + 94 Audio) ===";
        send_hex_file(rx, "data/golden/mixed_stream_clean.hex");
        wait for 50 us;

        -- Kuras sisa sampel audio di buffer
        drain_audio <= true;
        while unsigned(afifo_level) > 0 loop
            wait for 1 us;
        end loop;
        drain_audio <= false;
        wait for 20 us;

        assert cnt_valid_frames = 90
            report "Gagal: cnt_valid_frames " & integer'image(to_integer(cnt_valid_frames)) & " /= 90"
            severity failure;
        assert cnt_audio_packets = 94
            report "Gagal: cnt_audio_packets " & integer'image(to_integer(cnt_audio_packets)) & " /= 94"
            severity failure;
        assert cnt_chk_errors = 0
            report "Gagal: cnt_chk_errors /= 0" severity failure;
        assert cnt_len_errors = 0
            report "Gagal: cnt_len_errors /= 0" severity failure;
        assert cnt_resyncs = 0
            report "Gagal: cnt_resyncs /= 0" severity failure;

        assert video_bytes_verified = 92160
            report "Gagal: video_bytes_verified " & integer'image(video_bytes_verified) & " /= 92160"
            severity failure;
        assert video_mismatches = 0
            report "Gagal: Terdapat mismatch video!" severity failure;

        assert audio_bytes_verified = 25068
            report "Gagal: audio_bytes_verified " & integer'image(audio_bytes_verified) & " /= 25068"
            severity failure;
        assert audio_mismatches = 0
            report "Gagal: Terdapat mismatch papan skor audio!" severity failure;

        report "Uji 1 Berhasil: 90 frame video (92.160 B) dan 94 paket audio (25.068 B) byte-exact 100%!";
        check_ramp <= false;

        -- =====================================================================
        -- UJI 2: Vektor Checksum Audio Rusak (mixed_stream_corrupt_checksum.hex)
        -- =====================================================================
        report "=== [UJI 2] Mengirim data/golden/mixed_stream_corrupt_checksum.hex ===";
        rst <= '1';
        wait for 100 ns;
        rst <= '0';
        wait for 200 ns;

        send_hex_file(rx, "data/golden/mixed_stream_corrupt_checksum.hex");
        wait for 50 us;

        assert cnt_valid_frames = 90
            report "Gagal Uji 2: cnt_valid_frames /= 90" severity failure;
        assert cnt_audio_packets = 93
            report "Gagal Uji 2: cnt_audio_packets /= 93" severity failure;
        assert cnt_chk_errors = 1
            report "Gagal Uji 2: cnt_chk_errors /= 1" severity failure;
        assert cnt_aud_rollbacks = 1
            report "Gagal Uji 2: aud_rollback tidak dipancarkan saat galat checksum!" severity failure;

        report "Uji 2 Berhasil: Galat checksum audio terdeteksi persis, 93 paket audio lolos, video tetap 90 frame!";

        -- =====================================================================
        -- UJI 3: Vektor EOF Audio Rusak (mixed_stream_corrupt_eof.hex)
        -- =====================================================================
        report "=== [UJI 3] Mengirim data/golden/mixed_stream_corrupt_eof.hex ===";
        rst <= '1';
        wait for 100 ns;
        rst <= '0';
        wait for 200 ns;

        send_hex_file(rx, "data/golden/mixed_stream_corrupt_eof.hex");
        wait for 50 us;

        assert cnt_valid_frames = 90
            report "Gagal Uji 3: cnt_valid_frames /= 90" severity failure;
        assert cnt_audio_packets = 93
            report "Gagal Uji 3: cnt_audio_packets /= 93" severity failure;
        assert cnt_len_errors = 1
            report "Gagal Uji 3: cnt_len_errors /= 1" severity failure;

        report "Uji 3 Berhasil: Galat EOF audio terdeteksi persis, 93 paket audio lolos, video tetap 90 frame!";

        -- =====================================================================
        -- UJI 4: Vektor False SOF di Payload Audio (mixed_stream_payload_false_sof.hex)
        -- =====================================================================
        report "=== [UJI 4] Mengirim data/golden/mixed_stream_payload_false_sof.hex ===";
        rst <= '1';
        wait for 100 ns;
        rst <= '0';
        wait for 200 ns;

        send_hex_file(rx, "data/golden/mixed_stream_payload_false_sof.hex");
        wait for 50 us;

        assert cnt_valid_frames = 90
            report "Gagal Uji 4: cnt_valid_frames /= 90" severity failure;
        assert cnt_audio_packets = 94
            report "Gagal Uji 4: cnt_audio_packets /= 94" severity failure;
        assert cnt_resyncs = 0
            report "Gagal Uji 4: False SOF di payload audio memicu resync palsu!" severity failure;

        report "Uji 4 Berhasil: Pola 55 AA 5A dalam payload audio berhasil dikonsumsi sebagai data murni!";

        -- =====================================================================
        -- UJI 5: Vektor Audio Reject (mixed_stream_aud_reject.hex)
        -- =====================================================================
        report "=== [UJI 5] Mengirim data/golden/mixed_stream_aud_reject.hex (dengan aud_reject) ===";
        rst <= '1';
        wait for 100 ns;
        rst <= '0';
        wait for 200 ns;

        enable_force_reject <= '1';
        send_hex_file(rx, "data/golden/mixed_stream_aud_reject.hex");
        wait for 50 us;
        enable_force_reject <= '0';

        assert cnt_valid_frames = 90
            report "Gagal Uji 5: cnt_valid_frames /= 90" severity failure;
        assert cnt_audio_packets = 93
            report "Gagal Uji 5: cnt_audio_packets /= 93" severity failure;

        report "Uji 5 Berhasil: aud_reject berhasil mengonsumsi paket tanpa menaikkan counter!";

        -- =====================================================================
        -- UJI 6: Vektor Audio Terpotong (mixed_stream_truncated.hex)
        -- =====================================================================
        report "=== [UJI 6] Mengirim data/golden/mixed_stream_truncated.hex ===";
        rst <= '1';
        wait for 100 ns;
        rst <= '0';
        wait for 200 ns;

        send_hex_file(rx, "data/golden/mixed_stream_truncated.hex");
        -- Tunggu timeout watchdog memicu rollback
        wait for 200 us;

        assert cnt_valid_frames = 90
            report "Gagal Uji 6: cnt_valid_frames /= 90" severity failure;
        assert cnt_len_errors = 1
            report "Gagal Uji 6: Watchdog timeout tidak mencatat len_error!" severity failure;
        assert cnt_aud_rollbacks = 1
            report "Gagal Uji 6: aud_rollback tidak dipancarkan saat watchdog timeout!" severity failure;

        report "Uji 6 Berhasil: Timeout watchdog memicu rollback dan mencatat len_error!";

        -- =====================================================================
        -- UJI 7: Vektor LEN Audio = 63 (Di bawah batas 64 B)
        -- =====================================================================
        report "=== [UJI 7] Mengirim data/golden/mixed_stream_corrupt_len_63.hex ===";
        rst <= '1';
        wait for 100 ns;
        rst <= '0';
        wait for 200 ns;

        send_hex_file(rx, "data/golden/mixed_stream_corrupt_len_63.hex");
        wait for 50 us;

        assert cnt_valid_frames = 90
            report "Gagal Uji 7: cnt_valid_frames /= 90" severity failure;
        assert cnt_audio_packets = 93
            report "Gagal Uji 7: cnt_audio_packets /= 93" severity failure;
        assert cnt_len_errors = 1
            report "Gagal Uji 7: cnt_len_errors /= 1" severity failure;

        report "Uji 7 Berhasil: Paket audio dengan LEN < 64 ditolak sebagai galat panjang!";

        test_done <= true;
        report "================================================================";
        report "TEST PASSED: tb_parser_audio - SELURUH PENGUJIAN MANDIRI LOLOS!";
        report "================================================================";
        wait for 100 ns;
        stop;
    end process;

end architecture sim;
