-- hdl/top.vhd
-- Top-level entity untuk Proyek Bad Apple di Basys 3 (Milestone M1).
-- Mengintegrasikan:
-- 1. Reset synchronizer (2 FF) untuk tombol tengah (btnC).
-- 2. frame_timer: generator pulsa frame_tick 30 Hz dengan akumulator fase presisi.
-- 3. frame_source: membaca klip 90 frame BRAM kanonik (1024 B/frame).
-- 4. decoder: passthrough transparan untuk M1.
-- 5. frame_buffer: double-buffer ping-pong 2x1024 BRAM bebas tearing.
-- 6. ascii_sink: pengubah blok 2x4 kanonik ke teks ASCII 64x16 Ramp A (1.059 B/frame).
-- 7. uart_tx: pemancar UART 8N1 pada 921.600 baud ke chip FTDI FT2232HQ (RsTx).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity top is
    generic (
        CLK_FREQ_HZ  : integer := 100_000_000;
        BAUD_RATE    : integer := 921_600;
        TARGET_FPS   : integer := 30;
        TOTAL_FRAMES : integer := 90;
        INIT_FILE    : string  := "data/golden/clip_bram_32bit.hex"
    );
    port (
        clk  : in  std_logic;                    -- Pin W5: Osilator 100 MHz
        btnC : in  std_logic;                    -- Pin U18: Tombol Reset
        RsRx : in  std_logic;                    -- Pin B18: UART RX (cadangan)
        RsTx : out std_logic;                    -- Pin A18: UART TX ke PC
        led  : out std_logic_vector(3 downto 0)  -- Pin U16, E19, U19, V19: Status LED
    );
end entity top;

architecture rtl of top is
    -- 1. Reset Synchronizer (2-FF)
    signal rst_meta : std_logic := '1';
    signal rst_sync : std_logic := '1';

    -- 2. Frame Timer
    signal frame_tick_sig : std_logic;
    signal sink_start_reg : std_logic := '0';

    -- 3. Frame Source ke Decoder
    signal src_data  : std_logic_vector(7 downto 0);
    signal src_valid : std_logic;
    signal src_last  : std_logic;
    signal src_ready : std_logic;

    -- 4. Decoder ke Frame Buffer
    signal dec_data  : std_logic_vector(7 downto 0);
    signal dec_valid : std_logic;
    signal dec_last  : std_logic;
    signal dec_ready : std_logic;

    -- 5. Frame Buffer ke ASCII Sink
    signal fb_overrun  : std_logic;
    signal fb_underrun : std_logic;
    signal sink_fb_addr: unsigned(9 downto 0);
    signal fb_rd_data  : std_logic_vector(7 downto 0);

    -- 6. ASCII Sink ke UART TX
    signal sink_busy     : std_logic;
    signal sink_tx_data  : std_logic_vector(7 downto 0);
    signal sink_tx_valid : std_logic;
    signal sink_tx_ready : std_logic;

    -- 7. Register Status LED
    signal latched_underrun : std_logic := '0';
    signal latched_overrun  : std_logic := '0';
    signal heartbeat_cnt    : unsigned(23 downto 0) := (others => '0');
begin
    ---------------------------------------------------------------------------
    -- 1. Sinkronisasi Reset
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            rst_meta <= btnC;
            rst_sync <= rst_meta;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- 2. Modul Generator Waktu (frame_timer)
    ---------------------------------------------------------------------------
    u_timer : entity work.frame_timer
        generic map (
            CLK_FREQ_HZ => CLK_FREQ_HZ,
            TARGET_FPS  => TARGET_FPS
        )
        port map (
            clk        => clk,
            rst        => rst_sync,
            frame_tick => frame_tick_sig
        );

    -- Pulsa sink_start ditunda 1 siklus dari frame_tick untuk memastikan
    -- swap bank di frame_buffer telah selesai dan stabil (SPEC 4 & ARCHITECTURE 4.1)
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_sync = '1' then
                sink_start_reg <= '0';
            else
                sink_start_reg <= frame_tick_sig;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- 3. Sumber Frame BRAM (frame_source)
    ---------------------------------------------------------------------------
    u_source : entity work.frame_source
        generic map (
            TOTAL_FRAMES => TOTAL_FRAMES,
            FRAME_BYTES  => 1024,
            INIT_FILE    => INIT_FILE
        )
        port map (
            clk          => clk,
            rst          => rst_sync,
            start_frame  => frame_tick_sig,
            m_axis_data  => src_data,
            m_axis_valid => src_valid,
            m_axis_last  => src_last,
            m_axis_ready => src_ready
        );

    ---------------------------------------------------------------------------
    -- 4. Decoder Passthrough (decoder)
    ---------------------------------------------------------------------------
    u_dec : entity work.decoder
        port map (
            clk          => clk,
            rst          => rst_sync,
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
    -- 5. Double Buffer Ping-Pong (frame_buffer)
    ---------------------------------------------------------------------------
    u_buf : entity work.frame_buffer
        generic map (
            FRAME_BYTES => 1024
        )
        port map (
            clk          => clk,
            rst          => rst_sync,
            swap_req     => frame_tick_sig,
            read_busy    => sink_busy,
            overrun      => fb_overrun,
            underrun     => fb_underrun,
            s_axis_data  => dec_data,
            s_axis_valid => dec_valid,
            s_axis_ready => dec_ready,
            s_axis_last  => dec_last,
            rd_addr      => sink_fb_addr,
            rd_data      => fb_rd_data
        );

    ---------------------------------------------------------------------------
    -- 6. Display Sink ASCII (ascii_sink)
    ---------------------------------------------------------------------------
    u_sink : entity work.ascii_sink
        generic map (
            RAMP_SELECT => "RAMP_A"
        )
        port map (
            clk      => clk,
            rst      => rst_sync,
            start    => sink_start_reg,
            busy     => sink_busy,
            fb_addr  => sink_fb_addr,
            fb_data  => fb_rd_data,
            tx_data  => sink_tx_data,
            tx_valid => sink_tx_valid,
            tx_ready => sink_tx_ready
        );

    ---------------------------------------------------------------------------
    -- 7. Pemancar UART Serial (uart_tx)
    ---------------------------------------------------------------------------
    u_uart : entity work.uart_tx
        generic map (
            CLK_FREQ_HZ => CLK_FREQ_HZ,
            BAUD_RATE   => BAUD_RATE
        )
        port map (
            clk      => clk,
            rst      => rst_sync,
            tx_data  => sink_tx_data,
            tx_valid => sink_tx_valid,
            tx_ready => sink_tx_ready,
            RsTx     => RsTx
        );

    ---------------------------------------------------------------------------
    -- 8. Logika Indikator Status LED
    ---------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst_sync = '1' then
                latched_underrun <= '0';
                latched_overrun  <= '0';
                heartbeat_cnt    <= (others => '0');
            else
                heartbeat_cnt <= heartbeat_cnt + 1;

                if fb_underrun = '1' then
                    latched_underrun <= '1';
                end if;

                if fb_overrun = '1' then
                    latched_overrun <= '1';
                end if;
            end if;
        end if;
    end process;

    led(0) <= heartbeat_cnt(23); -- Heartbeat blink (~6 Hz pada 100 MHz)
    led(1) <= latched_underrun;  -- LED1: Underrun terdeteksi
    led(2) <= latched_overrun;   -- LED2: Overrun terdeteksi
    led(3) <= sink_busy;         -- LED3: Sink sedang aktif membaca/mengirim
end architecture rtl;
