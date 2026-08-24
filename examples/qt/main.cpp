#include <QApplication>
#include <QLabel>
#include <QSvgRenderer>

int main(int argc, char **argv)
{
    QApplication application(argc, argv);
    QSvgRenderer renderer;
    QLabel label(renderer.isValid() ? "Qt SVG ready" : "Qt cross-build ready");
    label.show();
    return application.exec();
}

