-- hdl/decoder.vhd
-- Modul decoder transparan (passthrough) untuk Milestone M1.
-- Pada M1, data dari frame_source sudah berupa frame kanonik 1-bit mentah (1024 byte/frame).
-- Pada M2, modul ini akan digantikan dengan entitas decoder RLE per baris (D-4).

library ieee;
use ieee.std_logic_1164.all;

entity decoder is
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;
        -- Input stream dari source
        s_axis_data  : in  std_logic_vector(7 downto 0);
        s_axis_valid : in  std_logic;
        s_axis_last  : in  std_logic;
        s_axis_ready : out std_logic;
        -- Output stream ke frame buffer
        m_axis_data  : out std_logic_vector(7 downto 0);
        m_axis_valid : out std_logic;
        m_axis_last  : out std_logic;
        m_axis_ready : in  std_logic
    );
end entity decoder;

architecture rtl of decoder is
begin
    -- Passthrough lurus tanpa latensi siklus
    m_axis_data  <= s_axis_data;
    m_axis_valid <= s_axis_valid;
    m_axis_last  <= s_axis_last;
    s_axis_ready <= m_axis_ready;
end architecture rtl;
