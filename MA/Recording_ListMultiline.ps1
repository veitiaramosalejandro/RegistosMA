if(-not ('MachiningMonitor.MultilineRecordingList' -as [type])){
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Text.RegularExpressions;
using System.Windows.Forms;
namespace MachiningMonitor {
 public sealed class MultilineRecordingList : ListView {
  private ImageList rowImages;
  public MultilineRecordingList() { OwnerDraw=true; DoubleBuffered=true; }
  public void UpdateRowHeights() {
   int lines=1;
   foreach(ListViewItem item in Items) foreach(ListViewItem.ListViewSubItem cell in item.SubItems)
    lines=Math.Max(lines,Regex.Split(cell.Text,@"\r\n|\r|\n").Length);
   int height=Math.Min(256,Math.Max(22,lines*Font.Height+8));
   if(rowImages!=null && rowImages.ImageSize.Height==height) { Invalidate(); return; }
   var images=new ImageList(); images.ImageSize=new Size(1,height); images.ColorDepth=ColorDepth.Depth32Bit;
   using(var blank=new Bitmap(1,height)) { images.Images.Add(blank); var handle=images.Handle; }
   var previous=rowImages; rowImages=images; SmallImageList=images;
   if(previous!=null) previous.Dispose();
   Invalidate();
  }
  protected override void OnDrawColumnHeader(DrawListViewColumnHeaderEventArgs e) { e.DrawDefault=true; }
  protected override void OnDrawItem(DrawListViewItemEventArgs e) {
   if(View!=View.Details) e.DrawDefault=true;
  }
  protected override void OnDrawSubItem(DrawListViewSubItemEventArgs e) {
   bool selected=e.Item.Selected;
   Color background=selected ? (Focused ? SystemColors.Highlight : SystemColors.ControlLight) : BackColor;
   Color foreground=selected && Focused ? SystemColors.HighlightText : ForeColor;
   using(var brush=new SolidBrush(background)) e.Graphics.FillRectangle(brush,e.Bounds);
   int y=e.Bounds.Top+4;
   foreach(string line in Regex.Split(e.SubItem.Text,@"\r\n|\r|\n")) {
    if(y+Font.Height>e.Bounds.Bottom) break;
    var rect=new Rectangle(e.Bounds.Left+4,y,Math.Max(0,e.Bounds.Width-8),Font.Height);
    TextRenderer.DrawText(e.Graphics,line,Font,rect,foreground,TextFormatFlags.SingleLine|TextFormatFlags.EndEllipsis|TextFormatFlags.NoPrefix|TextFormatFlags.PreserveGraphicsClipping);
    y+=Font.Height;
   }
  }
  protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); if(IsHandleCreated) UpdateRowHeights(); }
  protected override void Dispose(bool disposing) {
   if(disposing && rowImages!=null) { SmallImageList=null; rowImages.Dispose(); rowImages=null; }
   base.Dispose(disposing);
  }
 }
}
'@
}
