///|
test "plot input decoding accepts UTF-8 and PowerShell UTF-16 redirection" {
  let utf8_bom : Bytes = b"\xef\xbb\xbf{}"
  let decoded_utf8 = match decode_plot_bytes(utf8_bom) {
    Ok(value) => value
    Err(message) => abort("cannot decode UTF-8 trace: " + message)
  }
  inspect(decoded_utf8, content="{}")

  let utf16le = @utf16.encode("{}", bom=true)
  let decoded_utf16le = match decode_plot_bytes(utf16le) {
    Ok(value) => value
    Err(message) => abort("cannot decode UTF-16LE trace: " + message)
  }
  inspect(decoded_utf16le, content="{}")

  let utf16be = @utf16.encode("{}", bom=true, endianness=@utf16.Endian::Big)
  let decoded_utf16be = match decode_plot_bytes(utf16be) {
    Ok(value) => value
    Err(message) => abort("cannot decode UTF-16BE trace: " + message)
  }
  inspect(decoded_utf16be, content="{}")
}
