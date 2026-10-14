#include <OpenWithApplication.h>

bool OpenWithApplication::event(QEvent* event) {
    if (event->type() == QEvent::FileOpen) {
        QFileOpenEvent* openEvent = static_cast<QFileOpenEvent*>(event);
        // custom url schemes (e.g. sioyek:// links) are delivered as file open events without a file
        if (openEvent->url().isValid() && !openEvent->url().isLocalFile()) {
            emit url_ready(openEvent->url());
        }
        else {
            emit file_ready(openEvent->file());
        }
    }

    return QApplication::event(event);
}
