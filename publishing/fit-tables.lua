local width_sets = {
  [2] = {0.34, 0.66},
  [3] = {0.18, 0.36, 0.46},
  [4] = {0.18, 0.27, 0.27, 0.28},
}

function Table(tbl)
  local column_count = #tbl.colspecs
  local widths = width_sets[column_count]

  if widths == nil then
    widths = {}
    for i = 1, column_count do
      widths[i] = 1 / column_count
    end
  end

  for i, colspec in ipairs(tbl.colspecs) do
    tbl.colspecs[i] = { colspec[1], widths[i] }
  end

  return tbl
end

local code_delimiters = {"|", "!", "+", "@", "/", "~", "^", ":"}

function Code(el)
  if FORMAT ~= "latex" then
    return nil
  end

  for _, delimiter in ipairs(code_delimiters) do
    if not el.text:find(delimiter, 1, true) then
      return pandoc.RawInline(
        "latex",
        "\\begingroup\\renewcommand{\\UrlFont}{\\ttfamily}\\path" ..
          delimiter .. el.text .. delimiter .. "\\endgroup{}"
      )
    end
  end

  return nil
end
