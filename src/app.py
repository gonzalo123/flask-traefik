from flask import Flask
import os

app = Flask(__name__)


@app.get("/service1")
def health():
    return dict(
        status=True,
        slot=os.getenv('SLOT')
    )
