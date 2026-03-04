FROM python:slim-buster

WORKDIR /usr/src/app

COPY templates ./templates
COPY requirements.txt .
COPY data.json .
COPY app.py .

RUN pip3 install -r requirements.txt

ENV FLASK_APP=app.py
ENV FLASK_RUN_HOST=0.0.0.0

EXPOSE 5000

CMD ["flask", "run"]