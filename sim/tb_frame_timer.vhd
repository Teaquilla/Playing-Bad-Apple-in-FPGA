-- sim/tb_frame_timer.vhd
-- Testbench untuk frame_timer:
-- 1. Uji berskala: CLK=100 Hz, FPS=30 Hz selama 30 tick (tepat 100 siklus, jitter <= 1 siklus).
-- 2. Uji generic asli: CLK=100.000.000 Hz, FPS=30 Hz selama 3 tick (tepat 10.000.000 siklus, jitter <= 1 siklus).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_frame_timer is
end entity tb_frame_timer;

architecture sim of tb_frame_timer is
    constant CLK_PERIOD : time := 10 ns; -- 100 MHz clock

    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';
    signal tick_scaled  : std_logic;
    signal tick_real    : std_logic;

    -- UUT 1: Berskala (100 Hz / 30 Hz)
    constant TEST1_CLK : integer := 100;
    constant TEST1_FPS : integer := 30;

    -- UUT 2: Asli (100 MHz / 30 Hz)
    constant TEST2_CLK : integer := 100_000_000;
    constant TEST2_FPS : integer := 30;
begin
    -- Generator clock 100 MHz
    clk_process : process
    begin
        while true loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
    end process;

    -- UUT 1: Berskala
    uut1_scaled : entity work.frame_timer
        generic map (
            CLK_FREQ_HZ => TEST1_CLK,
            TARGET_FPS  => TEST1_FPS
        )
        port map (
            clk        => clk,
            rst        => rst,
            frame_tick => tick_scaled
        );

    -- UUT 2: Asli 100 MHz
    uut2_real : entity work.frame_timer
        generic map (
            CLK_FREQ_HZ => TEST2_CLK,
            TARGET_FPS  => TEST2_FPS
        )
        port map (
            clk        => clk,
            rst        => rst,
            frame_tick => tick_real
        );

    -- Stimulus & Verifikasi
    stim_proc : process
        -- Variabel Uji 1
        variable t1_count   : integer := 0;
        variable t1_since   : integer := 0;
        variable t1_total   : integer := 0;

        -- Variabel Uji 2
        variable t2_count   : integer := 0;
        variable t2_since   : integer := 0;
        variable t2_total   : integer := 0;
    begin
        -- Reset 50 ns
        rst <= '1';
        wait for 50 ns;
        wait until rising_edge(clk);
        rst <= '0';

        -----------------------------------------------------------------------
        -- UJI 1: Skala 100 Hz / 30 Hz (30 tick dalam 100 siklus)
        -----------------------------------------------------------------------
        report "=== MEMULAI UJI 1: frame_timer berskala (100 Hz, 30 FPS) ===" severity note;
        wait until rising_edge(clk) and tick_scaled = '1';
        t1_since := 0;
        t1_total := 0;

        while t1_count < 30 loop
            wait until rising_edge(clk);
            t1_since := t1_since + 1;
            t1_total := t1_total + 1;

            if tick_scaled = '1' then
                t1_count := t1_count + 1;
                assert (t1_since = 3 or t1_since = 4)
                    report "Uji 1: Pelanggaran jitter! Siklus antar tick = " & integer'image(t1_since)
                    severity failure;
                t1_since := 0;
            end if;
        end loop;

        assert t1_total = 100
            report "Uji 1: Total siklus tidak tepat 100! Terhitung = " & integer'image(t1_total)
            severity failure;
        report "UJI 1 SUKSES: 30 tick dalam tepat 100 siklus, jitter <= 1 siklus." severity note;

        -----------------------------------------------------------------------
        -- UJI 2: Generic Asli 100.000.000 Hz / 30 FPS (3 tick dalam 10.000.000 siklus)
        -- Interval per tick: 3.333.333 atau 3.333.334 siklus (jitter <= 1 siklus)
        -----------------------------------------------------------------------
        report "=== MEMULAI UJI 2: frame_timer asli (100 MHz, 30 FPS) ===" severity note;
        wait until rising_edge(clk) and tick_real = '1';
        t2_since := 0;
        t2_total := 0;

        while t2_count < 3 loop
            wait until rising_edge(clk);
            t2_since := t2_since + 1;
            t2_total := t2_total + 1;

            if tick_real = '1' then
                t2_count := t2_count + 1;
                report "Uji 2: Tick #" & integer'image(t2_count) & " pada siklus ke-" & integer'image(t2_since) severity note;

                assert (t2_since = 3333333 or t2_since = 3333334)
                    report "Uji 2: Pelanggaran jitter! Siklus = " & integer'image(t2_since)
                    severity failure;
                t2_since := 0;
            end if;
        end loop;

        assert t2_total = 10000000
            report "Uji 2: Total 3 tick tidak tepat 10.000.000 siklus! Terhitung = " & integer'image(t2_total)
            severity failure;

        report "UJI 2 SUKSES: 3 tick pada 100 MHz tepat dalam 10.000.000 siklus (periode rata-rata 33,33 ms, jitter <= 1 siklus)." severity note;
        report "TEST PASSED: frame_timer akurat pada uji berskala dan uji asli 100 MHz / 30 FPS." severity note;

        wait for 100 ns;
        std.env.stop;
    end process;
end architecture sim;
