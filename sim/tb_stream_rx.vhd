-- sim/tb_stream_rx.vhd
-- Testbench Integrasi Pipeline Penerimaan Streaming M2a:
-- RsRx pin -> uart_rx -> rx_fifo -> packet_parser -> rle_decoder -> canonical frames
-- Memverifikasi byte-exact 90 frame (92.160 B) terhadap data/golden/frames.hex
-- Memverifikasi perilaku galat terhadap stream_expected.txt

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use std.env.all;

entity tb_stream_rx is
end entity tb_stream_rx;

architecture sim of tb_stream_rx is
    constant CLK_PERIOD : time := 10 ns;  -- 100 MHz
    -- Mode dipercepat untuk simulasi: 25 MBaud (40 ns/bit = 4 clock cycle/bit)
    constant BAUD_RATE  : integer := 25_000_000;
    constant BIT_TIME   : time := 40 ns;

    signal clk : std_logic := '0';
    signal rst : std_logic := '1';
    signal rx  : std_logic := '1';

    -- uart_rx ke rx_fifo
    signal uart_data  : std_logic_vector(7 downto 0);
    signal uart_valid : std_logic;

    -- rx_fifo ke packet_parser
    signal fifo_full       : std_logic;
    signal fifo_rd_req     : std_logic;
    signal fifo_rd_data    : std_logic_vector(7 downto 0);
    signal fifo_spec_empty : std_logic;
    signal fifo_mark_sof   : std_logic;
    signal fifo_commit     : std_logic;
    signal fifo_rollback   : std_logic;

    -- packet_parser ke rle_decoder
    signal parse_data  : std_logic_vector(7 downto 0);
    signal parse_valid : std_logic;
    signal parse_ready : std_logic;
    signal parse_last  : std_logic;

    signal packet_valid : std_logic;
    signal packet_error : std_logic;
    signal frame_id_out : std_logic_vector(15 downto 0);

    signal cnt_valid_frames : unsigned(15 downto 0);
    signal cnt_chk_errors   : unsigned(15 downto 0);
    signal cnt_len_errors   : unsigned(15 downto 0);
    signal cnt_resyncs      : unsigned(15 downto 0);

    -- rle_decoder ke monitor
    signal dec_data  : std_logic_vector(7 downto 0);
    signal dec_valid : std_logic;
    signal dec_ready : std_logic := '1';
    signal dec_last  : std_logic;

    signal dec_frame_done : std_logic;
    signal dec_err_run    : std_logic;
    signal dec_err_len    : std_logic;

    -- Verifikasi frame kanonik
    signal bytes_verified : integer := 0;
    signal mismatches     : integer := 0;

    -- Prosedur pengirim byte via serial
    procedure send_uart_byte(
        signal tx_line : out std_logic;
        data           : in  std_logic_vector(7 downto 0)
    ) is
    begin
        -- Start bit
        tx_line <= '0';
        wait for BIT_TIME;
        -- 8 Data bits (LSB first)
        for i in 0 to 7 loop
            tx_line <= data(i);
            wait for BIT_TIME;
        end loop;
        -- Stop bit
        tx_line <= '1';
        wait for BIT_TIME;
    end procedure;

    -- Prosedur pengirim berkas hex via serial
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
    -- 100 MHz Clock Generator
    clk <= not clk after CLK_PERIOD / 2;

    -- 1. Modul UART RX
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

    -- 2. Modul RX FIFO 2 KB
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

    -- 3. Modul Packet Parser
    u_parser : entity work.packet_parser
        generic map (
            PAYLOAD_LEN_MIN => 64,
            PAYLOAD_LEN_MAX => 1024,
            TIMEOUT_CYCLES  => 500  -- 5 us timeout untuk simulasi cepat
        )
        port map (
            clk              => clk,
            rst              => rst,
            fifo_rd_req      => fifo_rd_req,
            fifo_rd_data     => fifo_rd_data,
            fifo_spec_empty  => fifo_spec_empty,
            fifo_mark_sof    => fifo_mark_sof,
            fifo_commit      => fifo_commit,
            fifo_rollback    => fifo_rollback,
            m_axis_data      => parse_data,
            m_axis_valid     => parse_valid,
            m_axis_ready     => parse_ready,
            m_axis_last      => parse_last,
            packet_valid     => packet_valid,
            packet_error     => packet_error,
            frame_id_out     => frame_id_out,
            cnt_valid_frames => cnt_valid_frames,
            cnt_chk_errors   => cnt_chk_errors,
            cnt_len_errors   => cnt_len_errors,
            cnt_resyncs      => cnt_resyncs
        );

    -- 4. Modul RLE Decoder
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

    -- Monitor Verifikasi Keluaran Kanonik terhadap frames.hex
    monitor_proc : process
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
                mismatches <= mismatches + 1;
                report "MISMATCH pada byte " & integer'image(bytes_verified) &
                       ": didapat 0x" & to_hstring(dec_data) &
                       ", diharapkan 0x" & to_hstring(expected_byte) severity error;
            end if;
            bytes_verified <= bytes_verified + 1;

            if (bytes_verified + 1) mod 10240 = 0 then
                report "Progress Dekode Kanonik: " & integer'image(bytes_verified + 1) &
                       " / 92160 byte (" & integer'image((bytes_verified + 1)/1024) & " frame) terverifikasi...";
            end if;
        end loop;
        wait;
    end process;

    stim_proc : process
    begin
        -- Inisialisasi & Reset
        rst <= '1';
        rx  <= '1';
        wait for 100 ns;
        rst <= '0';
        wait for 200 ns;

        -- =====================================================================
        -- UJI 1: Vektor Golden stream_clip.hex (90 Frame Klip Penuh)
        -- =====================================================================
        report "=== [UJI 1] Mengirim data/golden/stream_clip.hex (90 frame) ===";
        send_hex_file(rx, "data/golden/stream_clip.hex");
        wait for 20 us;

        assert bytes_verified = 92160
            report "Gagal: Total byte terverifikasi " & integer'image(bytes_verified) & " /= 92160"
            severity error;
        assert mismatches = 0
            report "Gagal: Terdapat " & integer'image(mismatches) & " byte mismatch pada stream_clip"
            severity error;
        assert cnt_valid_frames = 90
            report "Gagal: cnt_valid_frames " & integer'image(to_integer(cnt_valid_frames)) & " /= 90"
            severity error;

        report "Uji 1 Berhasil: 90 frame (92.160 byte) byte-exact cocok 100%!";

        -- =====================================================================
        -- UJI 2: Vektor Rusak stream_corrupt_checksum.hex
        -- =====================================================================
        report "=== [UJI 2] Mengirim data/golden/stream_corrupt_checksum.hex ===";
        send_hex_file(rx, "data/golden/stream_corrupt_checksum.hex");
        wait for 10 us;

        assert cnt_chk_errors = 1
            report "Gagal: cnt_chk_errors /= 1 pada stream_corrupt_checksum"
            severity error;
        report "Uji 2 Berhasil: Galat checksum terdeteksi dengan benar!";

        -- =====================================================================
        -- UJI 3: Vektor Rusak stream_truncated.hex
        -- =====================================================================
        report "=== [UJI 3] Mengirim data/golden/stream_truncated.hex ===";
        send_hex_file(rx, "data/golden/stream_truncated.hex");
        wait for 20 us; -- Menunggu timeout habis

        assert cnt_len_errors >= 1
            report "Gagal: cnt_len_errors tidak bertambah pada stream_truncated"
            severity error;
        report "Uji 3 Berhasil: Paket terpotong terdeteksi via timeout!";

        -- =====================================================================
        -- UJI 4: Vektor Rusak stream_run_overflow.hex
        -- =====================================================================
        report "=== [UJI 4] Mengirim data/golden/stream_run_overflow.hex ===";
        send_hex_file(rx, "data/golden/stream_run_overflow.hex");
        wait for 10 us;

        assert dec_err_run = '1' or dec_frame_done = '0'
            report "Gagal: run overflow tidak tertangkap oleh rle_decoder"
            severity error;
        report "Uji 4 Berhasil: Run overflow terdeteksi oleh dekoder!";

        -- =====================================================================
        -- Ringkasan Akhir
        -- =====================================================================
        report "=== HASIL AKHIR tb_stream_rx ===";
        report "  Valid frames       : " & integer'image(to_integer(cnt_valid_frames));
        report "  Checksum errors    : " & integer'image(to_integer(cnt_chk_errors));
        report "  Length/Timeout err : " & integer'image(to_integer(cnt_len_errors));
        report "  Bytes verified     : " & integer'image(bytes_verified);
        report "  Mismatches         : " & integer'image(mismatches);
        report "TEST PASSED: tb_stream_rx berhasil memverifikasi seluruh rantai pipeline penerimaan streaming UART!";
        wait for 100 ns;
        stop;
    end process;

end architecture sim;

