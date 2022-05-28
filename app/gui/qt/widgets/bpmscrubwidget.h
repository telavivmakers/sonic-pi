//--
// This file is part of Sonic Pi: http://sonic-pi.net
// Full project source: https://github.com/sonic-pi-net/sonic-pi
// License: https://github.com/sonic-pi-net/sonic-pi/blob/main/LICENSE.md
//
// Copyright 2022 by Sam Aaron (http://sam.aaron.name).
// All rights reserved.
//
// Permission is granted for use, copying, modification, and
// distribution of modified versions of this work as long as this
// notice is included.
//++
#ifndef BPMSCRUBWIDGET_H
#define BPMSCRUBWIDGET_H

#include <QWidget>
#include <QLineEdit>
#include <QMouseEvent>
#include <QPoint>
#include "model/sonicpitheme.h"
#include "qt_api_client.h"
#include "api/sonicpi_api.h"


class BPMScrubWidget : public QLineEdit
{
  Q_OBJECT

public:
  BPMScrubWidget(std::shared_ptr<SonicPi::QtAPIClient> spClient, std::shared_ptr<SonicPi::SonicPiAPI> spAPI, SonicPiTheme *theme, QWidget *parent = nullptr);

  void setBPM(double bpm);
  void setBPMLabel(double bpm);
  SonicPiTheme *theme;

signals:

public slots:

protected:
  void mousePressEvent(QMouseEvent * event);
  void mouseReleaseEvent(QMouseEvent * event);
  void mouseMoveEvent(QMouseEvent * event);

private:
  std::shared_ptr<SonicPi::QtAPIClient> m_spClient;
  std::shared_ptr<SonicPi::SonicPiAPI> m_spAPI;
  QPoint m_lastMouseClickPos;
  QPoint m_lastMouseClickGlobalPos;
  bool m_isDragging;
  double m_bpmValue, m_preDragBpmValue;
  void readAndSetBPM();

};

#endif // BPMSCRUBWIDGET_H
