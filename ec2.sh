#!/bin/bash
yum update -y
yum install python3 python3-pip -y
pip3 install flask boto3

cat << 'EOF' > /home/ec2-user/app.py
from flask import Flask, render_template_string
import boto3
from boto3.dynamodb.conditions import Key
from datetime import datetime, timedelta
import time

app = Flask(__name__)
dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
s3 = boto3.client('s3', region_name='us-east-1')

TABLE_NAME = 'ECG_Records'
table = dynamodb.Table(TABLE_NAME)
BUCKET_NAME = 'ecg-raw-archives'

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
        
        .Sensor.Terlepas { background-color: #8e44ad; color: white; animation: blinker 1s linear infinite; }
        @keyframes blinker { 50% { opacity: 0.1; } }
        
        .info-panel { background-color: #e8f4f8; padding: 15px; border-radius: 8px; margin-bottom: 15px; font-size: 11pt; border-left: 5px solid #2980b9; }
        
        table { width: 100%; border-collapse: collapse; margin-top: 15px; background: white; border-radius: 8px; overflow: hidden; }
        th, td { padding: 15px; text-align: left; }
        th { background-color: #34495e; color: white; font-weight: 500; font-size: 11pt; }
        td { border-bottom: 1px solid #eef2f5; font-size: 11pt; }
        
        .btn-grafik { background-color: #3498db; color: white; padding: 6px 12px; text-decoration: none; border-radius: 5px; font-size: 9.5pt; font-weight: bold; display: inline-block; transition: 0.2s;}
        .btn-grafik:hover { background-color: #2980b9; transform: scale(1.05); }
    </style>
</head>
<body>
    <div class="header-bar">
        <h1>🏥 Dashboard Monitoring ECG Real-Time</h1>
    </div>
    
    <div class="container">
        <div class="info-panel">
            <strong>Logika Jendela Waktu (Time Window):</strong> Data direkam terus-menerus dalam blok tepat berdurasi <strong>5 Detik</strong> (1250 sampel).<br>
            Blok terakhir direkam mulai dari <span style="color:#e74c3c; font-weight:bold;">{{ meta.start_indo }} WIB</span> hingga <span style="color:#e74c3c; font-weight:bold;">{{ meta.end_indo }} WIB</span>.
        </div>

        <div style="margin-bottom: 30px;">
            <h3 style="color: #2c3e50; margin-top: 0; border-bottom: 2px solid #eee; padding-bottom: 10px;">📈 Visualisasi Jendela Sinyal Terkini</h3>
            <div style="background: #fafafa; border: 1px solid #ddd; border-radius: 8px; padding: 15px; margin-top: 15px;">
                <canvas id="ecgChart" height="80"></canvas> 
            </div>
        </div>

        <table>
            <thead>
                <tr>
                    <th>Nama Pasien</th>
                    <th>Jendela Waktu Berakhir</th>
                    <th>BPM Terukur</th>
                    <th>Status Medis Pasien</th>
                    <th>Aksi</th>
                </tr>
            </thead>
            <tbody>
                {% for row in data %}
                <tr>
                    <td><strong>{{ row.nama_pasien }}</strong></td>
                    <td>{{ row.waktu_indo }}</td>
                    <td><strong style="font-size:13pt; color:#2c3e50;">{{ row.bpm }}</strong> BPM</td>
                    <td><span class="status-badge {{ row.status }}">{{ row.status }}</span></td>
                    <td>
                        {% if row.grafik_url %}
                            <a href="{{ row.grafik_url }}" target="_blank" class="btn-grafik">Lihat Sinyal 📈</a>
                        {% else %}
                            <span style="color:gray; font-size:10pt;">-</span>
                        {% endif %}
                    </td>
                </tr>
                {% endfor %}
            </tbody>
        </table>
    </div>

    <script>
        const rawData = {{ latest_signal | tojson }};
        const labels_waktu = {{ labels_waktu | tojson }};
        
        if (rawData && rawData.length > 0) {
            const ctx = document.getElementById('ecgChart').getContext('2d');
            
            new Chart(ctx, {
                type: 'line',
                data: {
                    labels: labels_waktu, // Sumbu X sekarang menggunakan timestamp WIB riil
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
                            title: { display: true, text: 'Waktu Perekaman (WIB)', font: { weight: 'bold' } },
                            ticks: {
                                maxTicksLimit: 10, // Membatasi agar teks timestamp tidak saling bertumpuk
                                maxRotation: 45,
                                minRotation: 45
                            }
                        },
                        y: { 
                            title: { display: true, text: 'ADC Value' },
                            suggestedMin: 1000, 
                            suggestedMax: 3000 
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
        labels_waktu = []
        meta_info = {'start_indo': '-', 'end_indo': '-'}

        if items:
            # Mengambil sinyal baris pertama (terbaru)
            raw_list = items[0].get('sinyal', [])
            latest_signal = [int(x) for x in raw_list]
            
            # Format waktu blok start & end
            start_epoch = int(items[0].get('start_time', 0))
            end_epoch = int(items[0].get('end_time', 0))
            
            s_time = datetime.utcfromtimestamp(start_epoch) + timedelta(hours=7)
            e_time = datetime.utcfromtimestamp(end_epoch) + timedelta(hours=7)
            
            meta_info['start_indo'] = s_time.strftime('%H:%M:%S')
            meta_info['end_indo'] = e_time.strftime('%H:%M:%S')

            # Menyusun label sumbu X untuk Chart.js (1250 sampel untuk 5 detik)
            for i in range(len(latest_signal)):
                dt = s_time + timedelta(seconds=(i / 250.0))
                # Tampilkan format Jam:Menit:Detik.Milidetik
                labels_waktu.append(dt.strftime('%H:%M:%S.%f')[:-4])
        
        for item in items:
            # Standarisasi WIB untuk tabel HTML
            waktu_utc = datetime.utcfromtimestamp(int(item['timestamp']))
            waktu_wib = waktu_utc + timedelta(hours=7)
            item['waktu_indo'] = waktu_wib.strftime('%Y-%m-%d %H:%M:%S WIB')
            
            # Membuat Tautan/URL Dinamis untuk setiap gambar Py yang disimpan di S3
            if item.get('s3_image_key'):
                item['grafik_url'] = s3.generate_presigned_url(
                    'get_object',
                    Params={'Bucket': BUCKET_NAME, 'Key': item['s3_image_key']},
                    ExpiresIn=3600 # Tautan akan expired dalam 1 jam
                )
            else:
                item['grafik_url'] = None
            
        return render_template_string(HTML_TEMPLATE, data=items, latest_signal=latest_signal, meta=meta_info, labels_waktu=labels_waktu)
    except Exception as e:
        return f"<h3>Gagal memuat database DynamoDB: {str(e)}</h3>"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)
EOF

sudo nohup python3 /home/ec2-user/app.py > /home/ec2-user/app.log 2>&1 &