#!/bin/bash
yum update -y
yum install python3 python3-pip -y
pip3 install flask boto3

cat << 'EOF' > /home/ec2-user/app.py
from flask import Flask, render_template_string
import boto3
from boto3.dynamodb.conditions import Key
import time

app = Flask(__name__)
dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
table = dynamodb.Table('ECG_Records')

HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>Sistem Monitoring Vital Sign ECG</title>
    <meta http-equiv="refresh" content="5">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 0; padding: 0; background-color: #f0f2f5; color: #333; }
        .header-bar { background-color: #2c3e50; color: white; padding: 25px; text-align: center; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .container { max-width: 1100px; margin: 30px auto; background: white; padding: 30px; border-radius: 12px; box-shadow: 0 4px 15px rgba(0,0,0,0.05); }
        h1 { margin: 0; font-size: 24pt; font-weight: 600; }
        
        .status-badge { padding: 6px 14px; border-radius: 20px; font-weight: bold; color: white; display: inline-block; font-size: 10pt; text-transform: uppercase; }
        .Normal { background-color: #2ecc71; box-shadow: 0 2px 5px rgba(46,204,113,0.3); }
        .Tachycardia { background-color: #e74c3c; box-shadow: 0 2px 5px rgba(231,76,60,0.3); }
        .Bradycardia { background-color: #f1c40f; color: #2c3e50; }
        
        .Sensor.Terlepas { 
            background-color: #8e44ad; color: white; 
            animation: blinker 1s linear infinite; 
        }
        @keyframes blinker { 50% { opacity: 0.1; } }
        
        .info-panel { background-color: #e8f4f8; padding: 15px; border-radius: 8px; margin-bottom: 15px; font-size: 11pt; border-left: 5px solid #2980b9; }
        
        table { width: 100%; border-collapse: collapse; margin-top: 15px; background: white; border-radius: 8px; overflow: hidden; }
        th, td { padding: 15px; text-align: left; }
        th { background-color: #34495e; color: white; font-weight: 500; font-size: 11pt; }
        td { border-bottom: 1px solid #eef2f5; font-size: 11pt; }
    </style>
</head>
<body>
    <div class="header-bar">
        <h1>🏥 Dashboard Monitoring ECG Real-Time</h1>
    </div>
    
    <div class="container">
        <div class="info-panel">
            <strong>Logika Jendela Waktu (Time Window):</strong> Data direkam terus-menerus dalam blok tepat berdurasi <strong>5 Detik</strong> (1250 sampel).<br>
            Blok terakhir direkam mulai dari <span style="color:#e74c3c;">{{ meta.start_indo }}</span> hingga <span style="color:#e74c3c;">{{ meta.end_indo }}</span>.
        </div>

        <div style="margin-bottom: 30px;">
            <h3 style="color: #2c3e50; margin-top: 0; border-bottom: 2px solid #eee; padding-bottom: 10px;">📈 Visualisasi Jendela Sinyal (0s - 5s)</h3>
            <div style="background: #fafafa; border: 1px solid #ddd; border-radius: 8px; padding: 15px; margin-top: 15px;">
                <canvas id="ecgChart" height="80"></canvas> 
            </div>
        </div>

        <table>
            <thead>
                <tr>
                    <th>Nama Pasien</th>
                    <th>ID Perangkat</th>
                    <th>Jendela Waktu Berakhir</th>
                    <th>BPM Terukur</th>
                    <th>Status Medis Pasien</th>
                </tr>
            </thead>
            <tbody>
                {% for row in data %}
                <tr>
                    <td><strong>{{ row.nama_pasien }}</strong></td>
                    <td>{{ row.device_id }}</td>
                    <td>{{ row.waktu_indo }}</td>
                    <td><strong style="font-size:13pt; color:#2c3e50;">{{ row.bpm }}</strong> BPM</td>
                    <td><span class="status-badge {{ row.status }}">{{ row.status }}</span></td>
                </tr>
                {% endfor %}
            </tbody>
        </table>
    </div>

    <script>
        const rawData = {{ latest_signal | tojson }};
        
        if (rawData && rawData.length > 0) {
            const ctx = document.getElementById('ecgChart').getContext('2d');
            
            // Masukan Penguji: Membuat label X-Axis berdasarkan Waktu aktual (0 sampai 5 detik)
            // Asumsi 1250 sampel untuk 5 detik (250Hz).
            const labels = Array.from({length: rawData.length}, (_, i) => {
                const detik = (i / 250).toFixed(2);
                return detik;
            });

            new Chart(ctx, {
                type: 'line',
                data: {
                    labels: labels,
                    datasets: [{
                        label: 'Sinyal ECG',
                        data: rawData,
                        borderColor: '#2980b9',
                        borderWidth: 1.5,
                        pointRadius: 0,
                        fill: false,
                        tension: 0.1
                    }]
                },
                options: {
                    animation: false,
                    scales: {
                        x: { 
                            display: true, 
                            title: { display: true, text: 'Waktu (Detik)', font: { weight: 'bold' } },
                            ticks: {
                                // Hanya tampilkan label waktu bulat (0, 1, 2, 3, 4, 5) agar rapi
                                callback: function(val, index) {
                                    return index % 250 === 0 ? (index / 250) + 's' : '';
                                }
                            }
                        },
                        y: { 
                            title: { display: true, text: 'ADC Value' },
                            suggestedMin: 1500, 
                            suggestedMax: 2500 
                        }
                    },
                    plugins: { legend: { display: false } },
                    interaction: { intersect: false, mode: 'index' },
                }
            });
        } else {
            const ctx = document.getElementById('ecgChart').getContext('2d');
            ctx.font = "16px 'Segoe UI'";
            ctx.fillStyle = "#e74c3c";
            ctx.textAlign = "center";
            ctx.fillText("Menunggu transmisi data 5-detik atau sensor terlepas...", document.getElementById('ecgChart').width/2, document.getElementById('ecgChart').height/2);
        }
    </script>
</body>
</html>
"""

@app.route('/')
def index():
    try:
        response = table.query(
            KeyConditionExpression=Key('device_id').eq('ESP32-ECG-PRO'),
            ScanIndexForward=False, 
            Limit=10
        )
        
        items = response.get('Items', [])
        latest_signal = []
        meta_info = {'start_indo': '-', 'end_indo': '-'}

        if items:
            raw_list = items[0].get('sinyal', [])
            latest_signal = [int(x) for x in raw_list]
            
            # Format waktu start dan end
            s_time = time.localtime(int(items[0].get('start_time', 0)))
            e_time = time.localtime(int(items[0].get('end_time', 0)))
            meta_info['start_indo'] = time.strftime('%H:%M:%S', s_time)
            meta_info['end_indo'] = time.strftime('%H:%M:%S', e_time)
        
        for item in items:
            waktu_lokal = time.localtime(int(item['timestamp']))
            item['waktu_indo'] = time.strftime('%Y-%m-%d %H:%M:%S', waktu_lokal)
            
        return render_template_string(HTML_TEMPLATE, data=items, latest_signal=latest_signal, meta=meta_info)
    except Exception as e:
        return f"<h3>Gagal memuat database DynamoDB: {str(e)}</h3>"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)
EOF

sudo nohup python3 /home/ec2-user/app.py > /home/ec2-user/app.log 2>&1 &