package chat.simplex.app.ui.theme

import androidx.compose.material.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.*
import androidx.compose.ui.unit.sp
import chat.simplex.res.MR

// https://github.com/rsms/inter
val Inter: FontFamily = FontFamily(
  Font(MR.fonts.Inter.regular.fontResourceId),
  Font(MR.fonts.Inter.italic.fontResourceId, style = FontStyle.Italic),
  Font(MR.fonts.Inter.bold.fontResourceId, FontWeight.Bold),
  Font(MR.fonts.Inter.semibold.fontResourceId, FontWeight.SemiBold),
  Font(MR.fonts.Inter.medium.fontResourceId, FontWeight.Medium),
  Font(MR.fonts.Inter.light.fontResourceId, FontWeight.Light)
)

// Set of Material typography styles to start with
val Typography = Typography(
  h1 = TextStyle(
    fontFamily = Inter,
    fontWeight = FontWeight.Bold,
    fontSize = 32.sp,
  ),
  h2 = TextStyle(
    fontFamily = Inter,
    fontWeight = FontWeight.Normal,
    fontSize = 24.sp
  ),
  h3 = TextStyle(
    fontFamily = Inter,
    fontWeight = FontWeight.Normal,
    fontSize = 18.5.sp
  ),
  h4 = TextStyle(
    fontFamily = Inter,
    fontWeight = FontWeight.Normal,
    fontSize = 17.5.sp
  ),
  body1 = TextStyle(
    fontFamily = Inter,
    fontWeight = FontWeight.Normal,
    fontSize = 16.sp
  ),
  body2 = TextStyle(
    fontFamily = Inter,
    fontWeight = FontWeight.Normal,
    fontSize = 14.sp
  ),
  button = TextStyle(
    fontFamily = Inter,
    fontWeight = FontWeight.Normal,
    fontSize = 16.sp,
  ),
  caption = TextStyle(
    fontFamily = Inter,
    fontWeight = FontWeight.Normal,
    fontSize = 18.sp
  )
)
