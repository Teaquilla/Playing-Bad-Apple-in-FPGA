-- hdl/frame_timer.vhd
-- Generator sinyal frame_tick untuk menyinkronkan seluruh pipeline video.
-- Menggunakan akumulator fraksional presisi tinggi (Bresenham clock divider)
-- untuk menjamin rata-rata frekuensi tepat TARGET_FPS tanpa drift jangka panjang,
-- dengan jitter maksimum <= 1 siklus clock (10 ns pada 100 MHz).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity frame_timer is
    generic (
        CLK_FREQ_HZ : integer := 100_000_000;
        TARGET_FPS  : integer := 30
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        frame_tick : out std_logic
    );
end entity frame_timer;

architecture rtl of frame_timer is
    -- Akumulator 32-bit untuk mengakomodasi frekuensi clock hingga ratusan MHz
    signal acc : unsigned(31 downto 0) := (others => '0');
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                acc        <= (others => '0');
                frame_tick <= '0';
            else
                if (acc + to_unsigned(TARGET_FPS, 32)) >= to_unsigned(CLK_FREQ_HZ, 32) then
                    acc        <= acc + to_unsigned(TARGET_FPS, 32) - to_unsigned(CLK_FREQ_HZ, 32);
                    frame_tick <= '1';
                else
                    acc        <= acc + to_unsigned(TARGET_FPS, 32);
                    frame_tick <= '0';
                end if;
            end if;
        end if;
    end process;
end architecture rtl;
