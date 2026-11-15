-- hdl/top.vhd
-- Top-level entity untuk Proyek Bad Apple di Basys 3 (Milestone M1 & M2b).
-- Mengintegrasikan:
-- 1. Reset synchronizer (2 FF) untuk tombol tengah (btnC).
-- 2. Switch synchronizer (2 FF) untuk saklar SW0 dengan auto-reset saat perpindahan mode.
--    - SW0 = '0' : Mode Klip On-Chip BRAM (M1) dengan frame_timer 30 FPS.
--    - SW0 = '1' : Mode Streaming UART RX dari PC (M2) dengan buffer swap tertunda.
-- 3. Jalur Data M1: frame_timer, frame_source, decoder.
-- 4. Jalur Data M2: uart_rx, rx_fifo (2KB BRAM), packet_parser, rle_decoder.
-- 5. frame_buffer: double-buffer ping-pong 2x1024 BRAM bebas tearing.
-- 6. ascii_sink: pengubah blok 2x4 kanonik ke teks ASCII 64x16 Ramp A (1.059 B/frame).
-- 7. uart_tx: pemancar UART 8N1 pada 921.600 baud ke chip FTDI FT2232HQ (RsTx).
-- 8. Indikator Status LED 8-bit pada Basys 3.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top is
    generic (
        CLK_FREQ_HZ  : integer := 100_000_000;
        BAUD_RATE    : integer := 921_600;
        TARGET_FPS   : integer := 30;
        TOTAL_FRAMES   : integer := 90;
        INIT_FILE      : string  := "data/golden/clip_bram_32bit.hex";
        OLED_REMAP_SEG : std_logic_vector(7 downto 0) := x"A1";
        OLED_REMAP_COM : std_logic_vector(7 downto 0) := x"C8"
    );
    port (
        clk  : in  std_logic;                                      -- Pin W5: Osilator 100 MHz
        btnC : in  std_logic;                                      -- Pin U18: Tombol Reset
        sw   : in  std_logic_vector(0 downto 0) := (others => '0');-- Pin V17: Saklar SW0 (0: Klip, 1: Streaming)
        RsRx      : in  std_logic := '1';                               -- Pin B18: UART RX dari PC
        RsTx      : out std_logic;                                      -- Pin A18: UART TX ke PC
        led       : out std_logic_vector(7 downto 0);                   -- Pin U16..V14: Status LED

        -- Antarmuka PMOD JA: Display OLED SPI SSD1306 (M4)
        oled_res  : out std_logic := '1';
        oled_dc   : out std_logic := '0';
        oled_cs   : out std_logic := '1';
        oled_sclk : out std_logic := '0';
        oled_mosi : out std_logic := '0'
    );
end entity top;

architecture rtl of top is
    -- 1. Sinkronisasi Reset (btnC) & Switch (SW0)
    signal rst_meta : std_logic := '1';
    signal rst_sync : std_logic := '1';

    signal sw_meta  : std_logic := '0';
    signal sw_sync  : std_logic := '0';
    signal sw_prev  : std_logic := '0';
    signal rst_mode : std_logic := '0';

    signal rst_int  : std_logic := '1';

    -- 2. Frame Timer (Mode M1)
    signal frame_tick_sig : std_logic;
    signal sink_start_reg : std_logic := '0';

    -- 3. Frame Source ke Decoder (Mode M1)
    signal src_data  : std_logic_vector(7 downto 0);
    signal src_valid : std_logic;
    signal src_last  : std_logic;
    signal src_ready : std_logic;

    -- 4. Decoder Passthrough ke Frame Buffer (Mode M1)
    signal dec_data  : std_logic_vector(7 downto 0);
    signal dec_valid : std_logic;
    signal dec_last  : std_logic;
    signal dec_ready : std_logic;

    -- 5. Rantai Penerima Streaming UART RX (Mode M2)
    signal rx_byte         : std_logic_vector(7 downto 0);
    signal rx_byte_valid   : std_logic;

    signal fifo_rd_data    : std_logic_vector(7 downto 0);
    signal fifo_empty      : std_logic;
    signal fifo_rd_req     : std_logic;
    signal fifo_commit     : std_logic;
    signal fifo_rollback   : std_logic;
    signal fifo_rollback_to_sof : std_logic;
    signal fifo_mark_sof   : std_logic;

    signal parser_payload_data  : std_logic_vector(7 downto 0);
    signal parser_payload_valid : std_logic;
    signal parser_payload_ready : std_logic;
    signal parser_payload_last  : std_logic;
    signal parser_packet_valid  : std_logic;
    signal parser_packet_error  : std_logic;
    signal err_checksum_cnt     : unsigned(15 downto 0);
    signal err_length_cnt       : unsigned(15 downto 0);
    signal err_resync_cnt       : unsigned(15 downto 0);

    signal rle_dec_data  : std_logic_vector(7 downto 0);
    signal rle_dec_valid : std_logic;
    signal rle_dec_last  : std_logic;
    signal rle_dec_ready : std_logic;
    signal rle_err_run   : std_logic;
    signal rle_err_len   : std_logic;

    signal stream_drop_sig : std_logic;

    -- 6. Multiplexer Masukan ke Frame Buffer
    signal fb_s_axis_data  : std_logic_vector(7 downto 0);
    signal fb_s_axis_valid : std_logic;
    signal fb_s_axis_ready : std_logic;
    signal fb_s_axis_last  : std_logic;

    signal fb_overrun        : std_logic;
    signal fb_underrun       : std_logic;
    signal fb_stream_overrun : std_logic;
    signal fb_swap_done      : std_logic;

    signal sink_fb_addr: unsigned(9 downto 0);
    signal fb_rd_data  : std_logic_vector(7 downto 0);
    signal fb_rd2_data : std_logic_vector(7 downto 0);

    -- Sinyal Pengendali Display OLED SPI (M4)
    signal oled_start         : std_logic := '0';
    signal oled_busy          : std_logic;
    signal oled_init_done     : std_logic;
    signal oled_frame_pending : std_logic := '0';
    signal oled_rd_addr       : std_logic_vector(9 downto 0);

    -- 7. ASCII Sink ke UART TX
    signal sink_start    : std_logic;
    signal sink_busy     : std_logic;
    signal sink_tx_data  : std_logic_vector(7 downto 0);
    signal sink_tx_valid : std_logic;
    signal sink_tx_ready : std_logic;

    -- 8. Register Status & Latch Galat LED
    signal latched_underrun        : std_logic := '0';
    signal latched_overrun         : std_logic := '0';
    signal latched_err_checksum    : std_logic := '0';
    signal latched_err_len_timeout : std_logic := '0';
    signal latched_stream_overrun  : std_logic := '0';
    signal heartbeat_cnt           : unsigned(23 downto 0) := (others => '0');
begin
    ---------------------------------------------------------------------------
    -- 1. Sinkronisasi Reset (btnC) & Switch Mode (SW0)
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            rst_meta <= btnC;
            rst_sync <= rst_meta;

            sw_meta  <= sw(0);
            sw_sync  <= sw_meta;

            -- Deteksi perpindahan mode saklar -> reset internal 1 siklus
            if sw_sync /= sw_prev then
                rst_mode <= '1';
            else
                rst_mode <= '0';
            end if;
            sw_prev <= sw_sync;
        end if;
    end process;

    rst_int <= rst_sync or rst_mode;

    ---------------------------------------------------------------------------
    -- 2. Modul Generator Waktu (frame_timer) - Mode M1
    ---------------------------------------------------------------------------
    u_timer : entity work.frame_timer
        generic map (
            CLK_FREQ_HZ => CLK_FREQ_HZ,
            TARGET_FPS  => TARGET_FPS
        )
        port map (
            clk        => clk,
            rst        => rst_int,
            frame_tick => frame_tick_sig
        );

    -- Pulsa sink_start ditunda 1 siklus pada mode M1
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                sink_start_reg <= '0';
            else
                sink_start_reg <= frame_tick_sig;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- 3. Sumber Frame BRAM (frame_source) - Mode M1
    ---------------------------------------------------------------------------
    u_source : entity work.frame_source
        generic map (
            TOTAL_FRAMES => TOTAL_FRAMES,
            FRAME_BYTES  => 1024,
            INIT_FILE    => INIT_FILE
        )
        port map (
            clk          => clk,
            rst          => rst_int,
            start_frame  => frame_tick_sig,
            m_axis_data  => src_data,
            m_axis_valid => src_valid,
            m_axis_last  => src_last,
            m_axis_ready => src_ready
        );

    ---------------------------------------------------------------------------
    -- 4. Decoder Passthrough (decoder) - Mode M1
    ---------------------------------------------------------------------------
    u_dec : entity work.decoder
        port map (
            clk          => clk,
            rst          => rst_int,
            s_axis_data  => src_data,
            s_axis_valid => src_valid,
            s_axis_last  => src_last,
            s_axis_ready => src_ready,
            m_axis_data  => dec_data,
            m_axis_valid => dec_valid,
            m_axis_last  => dec_last,
            m_axis_ready => dec_ready
        );

    ---------------------------------------------------------------------------
    -- 5. Rantai Penerima Streaming UART RX - Mode M2
    ---------------------------------------------------------------------------
    u_uart_rx : entity work.uart_rx
        generic map (
            CLK_FREQ_HZ => CLK_FREQ_HZ,
            BAUD_RATE   => BAUD_RATE
        )
        port map (
            clk     => clk,
            rst     => rst_int,
            rx      => RsRx,
            m_data  => rx_byte,
            m_valid => rx_byte_valid
        );

    u_fifo : entity work.rx_fifo
        generic map (
            FIFO_DEPTH => 2048
        )
        port map (
            clk                 => clk,
            rst                 => rst_int,
            wr_en               => rx_byte_valid,
            wr_data             => rx_byte,
            full                => open,
            rd_req              => fifo_rd_req,
            rd_data             => fifo_rd_data,
            spec_empty          => fifo_empty,
            mark_sof            => fifo_mark_sof,
            commit              => fifo_commit,
            rollback            => fifo_rollback,
            commit_empty        => open,
            overflow_err        => open
        );

    u_parser : entity work.packet_parser
        generic map (
            TIMEOUT_CYCLES => 2_000_000
        )
        port map (
            clk                 => clk,
            rst                 => rst_int,
            fifo_rd_req         => fifo_rd_req,
            fifo_rd_data        => fifo_rd_data,
            fifo_spec_empty     => fifo_empty,
            fifo_mark_sof       => fifo_mark_sof,
            fifo_commit         => fifo_commit,
            fifo_rollback       => fifo_rollback,
            m_axis_data         => parser_payload_data,
            m_axis_valid        => parser_payload_valid,
            m_axis_ready        => parser_payload_ready,
            m_axis_last         => parser_payload_last,
            packet_valid        => parser_packet_valid,
            packet_error        => parser_packet_error,
            frame_id_out        => open,
            cnt_valid_frames    => open,
            cnt_chk_errors      => err_checksum_cnt,
            cnt_len_errors      => err_length_cnt,
            cnt_resyncs         => err_resync_cnt
        );

    u_rle_dec : entity work.rle_decoder
        port map (
            clk          => clk,
            rst          => rst_int,
            s_axis_data  => parser_payload_data,
            s_axis_valid => parser_payload_valid,
            s_axis_ready => parser_payload_ready,
            s_axis_last  => parser_payload_last,
            m_axis_data  => rle_dec_data,
            m_axis_valid => rle_dec_valid,
            m_axis_ready => rle_dec_ready,
            m_axis_last  => rle_dec_last,
            frame_done   => open,
            err_run      => rle_err_run,
            err_len      => rle_err_len
        );

    stream_drop_sig <= parser_packet_error or rle_err_run or rle_err_len;

    ---------------------------------------------------------------------------
    -- 6. Multiplexer Sumber Data ke Frame Buffer
    ---------------------------------------------------------------------------
    process(sw_sync, dec_data, dec_valid, dec_last, fb_s_axis_ready,
            rle_dec_data, rle_dec_valid, rle_dec_last)
    begin
        if sw_sync = '0' then
            -- Mode M1: BRAM Clip
            fb_s_axis_data  <= dec_data;
            fb_s_axis_valid <= dec_valid;
            fb_s_axis_last  <= dec_last;
            dec_ready       <= fb_s_axis_ready;
            rle_dec_ready   <= '0';
        else
            -- Mode M2: Streaming UART RX
            fb_s_axis_data  <= rle_dec_data;
            fb_s_axis_valid <= rle_dec_valid;
            fb_s_axis_last  <= rle_dec_last;
            rle_dec_ready   <= fb_s_axis_ready;
            dec_ready       <= '0';
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- 7. Double Buffer Ping-Pong (frame_buffer)
    ---------------------------------------------------------------------------
    u_buf : entity work.frame_buffer
        generic map (
            FRAME_BYTES => 1024
        )
        port map (
            clk            => clk,
            rst            => rst_int,
            streaming_mode => sw_sync,
            swap_req       => frame_tick_sig,
            read_busy      => sink_busy,
            overrun        => fb_overrun,
            underrun       => fb_underrun,
            stream_valid   => parser_packet_valid,
            stream_drop    => stream_drop_sig,
            stream_overrun => fb_stream_overrun,
            swap_done      => fb_swap_done,
            s_axis_data    => fb_s_axis_data,
            s_axis_valid   => fb_s_axis_valid,
            s_axis_ready   => fb_s_axis_ready,
            s_axis_last    => fb_s_axis_last,
            rd_addr        => sink_fb_addr,
            rd_data        => fb_rd_data,
            rd2_addr       => unsigned(oled_rd_addr),
            rd2_data       => fb_rd2_data
        );

    -- Pemicu mulai display: M1 dipicu timer 30 FPS, M2 dipicu selesai swap buffer
    sink_start <= sink_start_reg when (sw_sync = '0') else fb_swap_done;

    ---------------------------------------------------------------------------
    -- 8. Display Sink ASCII (ascii_sink)
    ---------------------------------------------------------------------------
    u_sink : entity work.ascii_sink
        generic map (
            RAMP_SELECT => "RAMP_A"
        )
        port map (
            clk      => clk,
            rst      => rst_int,
            start    => sink_start,
            busy     => sink_busy,
            fb_addr  => sink_fb_addr,
            fb_data  => fb_rd_data,
            tx_data  => sink_tx_data,
            tx_valid => sink_tx_valid,
            tx_ready => sink_tx_ready
        );

    ---------------------------------------------------------------------------
    -- 9. Pemancar UART Serial (uart_tx)
    ---------------------------------------------------------------------------
    u_uart_tx : entity work.uart_tx
        generic map (
            CLK_FREQ_HZ => CLK_FREQ_HZ,
            BAUD_RATE   => BAUD_RATE
        )
        port map (
            clk      => clk,
            rst      => rst_int,
            tx_data  => sink_tx_data,
            tx_valid => sink_tx_valid,
            tx_ready => sink_tx_ready,
            RsTx     => RsTx
        );

    ---------------------------------------------------------------------------
    -- 9b. Pengendali Display OLED SPI SSD1306 (oled_spi) - PMOD JA (M4)
    ---------------------------------------------------------------------------
    u_oled : entity work.oled_spi
        generic map (
            CLK_DIV         => 16,
            REMAP_SEG       => OLED_REMAP_SEG,
            REMAP_COM       => OLED_REMAP_COM,
            CONTRAST        => x"CF",
            INVERT_DATA     => false,
            READ_LATENCY    => 1,
            RES_LOW_CYCLES  => 1_000,
            RES_WAIT_CYCLES => 100_000,
            CS_SETUP_CYCLES => 3,
            CS_HOLD_CYCLES  => 2
        )
        port map (
            clk       => clk,
            rst       => rst_int,
            start     => oled_start,
            busy      => oled_busy,
            rd_addr   => oled_rd_addr,
            rd_data   => fb_rd2_data,
            oled_res  => oled_res,
            oled_dc   => oled_dc,
            oled_cs   => oled_cs,
            oled_sclk => oled_sclk,
            oled_mosi => oled_mosi,
            init_done => oled_init_done
        );

    -- Logika frame_pending pengendali OLED:
    -- Flag frame_pending diset oleh pulsa swap (fb_swap_done).
    -- oled_start dipancarkan hanya bila ada frame pending, oled_spi idle, dan init_done aktif.
    -- Bekerja identik pada Mode M1 (Klip ROM) dan Mode M2 (Streaming UART).
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                oled_frame_pending <= '0';
                oled_start         <= '0';
            else
                oled_start <= '0';

                if fb_swap_done = '1' then
                    oled_frame_pending <= '1';
                end if;

                if (oled_frame_pending = '1') and 
                   (oled_busy = '0') and (oled_init_done = '1') and (oled_start = '0') then
                    oled_start         <= '1';
                    oled_frame_pending <= '0';
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- 10. Logika Indikator Status LED
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_int = '1' then
                latched_underrun        <= '0';
                latched_overrun         <= '0';
                latched_err_checksum    <= '0';
                latched_err_len_timeout <= '0';
                latched_stream_overrun  <= '0';
                heartbeat_cnt           <= (others => '0');
            else
                heartbeat_cnt <= heartbeat_cnt + 1;

                if fb_underrun = '1' then
                    latched_underrun <= '1';
                end if;

                if fb_overrun = '1' then
                    latched_overrun <= '1';
                end if;

                if err_checksum_cnt /= 0 then
                    latched_err_checksum <= '1';
                end if;

                if err_length_cnt /= 0 then
                    latched_err_len_timeout <= '1';
                end if;

                if fb_stream_overrun = '1' then
                    latched_stream_overrun <= '1';
                end if;
            end if;
        end if;
    end process;

    led(0) <= heartbeat_cnt(23);           -- LED0: Heartbeat blink (~6 Hz pada 100 MHz)
    led(1) <= sw_sync;                    -- LED1: Mode aktif ('0' = M1 Klip, '1' = M2 Streaming)
    led(2) <= sink_busy;                  -- LED2: Sink sedang aktif membaca/mengirim ASCII
    led(3) <= latched_underrun;           -- LED3: Underrun terdeteksi (M1)
    led(4) <= latched_overrun;            -- LED4: Overrun terdeteksi (M1)
    led(5) <= latched_err_checksum;       -- LED5: Galat checksum terdeteksi (M2)
    led(6) <= latched_err_len_timeout;    -- LED6: Galat panjang / timeout terdeteksi (M2)
    led(7) <= latched_stream_overrun;     -- LED7: Streaming overrun terdeteksi (M2)
end architecture rtl;
