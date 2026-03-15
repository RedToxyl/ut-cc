import azure.functions as func
import logging
import uuid
import json
from datetime import datetime

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

@app.route(route="htmlForm")
def htmlForm(req: func.HttpRequest) -> func.HttpResponse:
    logging.info('Python HTTP trigger function processed a request.')

    html_data = """
        <html>
        <title>Garfishs Holy Words</title>
        <body>
        <h4> Welcome to the Garfish message board. </h4>
        <h4> Enter a new message</h4>
        <form action='/api/handleMessage'>
            <label> Your message: </label><br>
            <input type='text' name='msg'><br>
            <input type='submit' value='Submit'>
        </form>
        </body>
        </html> """

    return func.HttpResponse(
    html_data,
    status_code=201,
    mimetype="text/html"
)

@app.cosmos_db_output(arg_name="outputDocument", database_name="messagesdb", container_name = "messages", create_if_not_exists=False, connection="CosmosDB")
@app.route(route="handleMessage", auth_level=func.AuthLevel.ANONYMOUS)
def handleMessage(req: func.HttpRequest, outputDocument: func.Out[func.Document]) -> func.HttpResponse:
    logging.info('Python HTTP trigger function processed a request.')
    msg = req.params.get('msg')
    rowKey = str(uuid.uuid4())

    json_message = {
        'content': msg,
        'id':  rowKey,
        'message_time': datetime.now().isoformat(" ", "seconds")}

    outputDocument.set(func.Document.from_dict(json_message))

    return func.HttpResponse(
        f"Entered message was: {msg}. <link href='/api/htmlForm'>Enter another message</link>",
        status_code=201,
        mimetype="text/html"
)