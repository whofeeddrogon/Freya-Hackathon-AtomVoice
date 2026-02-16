# 1. Aşama: Python tabanlı hafif imaj kullanıyoruz
FROM python:3.10-slim

# Çalışma dizinini oluştur
WORKDIR /app

# Sistem bağımlılıklarını kur (Ses işleme kütüphaneleri için gerekebilir)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

# Bağımlılıkları kopyala ve kur
# Not: requirements.txt çok büyük (torch vb.) olduğu için optimize edilmiş requirements.prod.txt kullanıyoruz
COPY requirements.prod.txt .
RUN pip install --no-cache-dir -r requirements.prod.txt

# Uygulama kodlarını kopyala
COPY . .

# .env.example'ı varsa kopyala (deployment'ta gerçek .env mount edilecek veya ENV olarak verilecek)
# RUN cp .env.example .env

# Portu ayarla
EXPOSE 3000

# Environment değişkenleri (Docker run sırasında ezilebilir)
ENV HOST=0.0.0.0
ENV PORT=3000
ENV DEBUG_LOGGING=false

# Uygulamayı başlat
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "3000"]
