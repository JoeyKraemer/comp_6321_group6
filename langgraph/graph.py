from typing import TypedDict

from langgraph.graph import END, START, StateGraph


class State(TypedDict):
    message: str


def respond(state: State) -> State:
    return {"message": state["message"]}


builder = StateGraph(State)
builder.add_node("respond", respond)
builder.add_edge(START, "respond")
builder.add_edge("respond", END)
graph = builder.compile()
